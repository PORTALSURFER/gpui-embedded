//! Smoke-test an explicitly owned native surface without starting an app loop.
#![allow(deprecated, unexpected_cfgs)]

#[cfg(target_os = "macos")]
mod native {
    use cocoa::appkit::{NSApp, NSBackingStoreType, NSView, NSWindow, NSWindowStyleMask};
    use cocoa::base::{id, nil};
    use cocoa::foundation::{NSAutoreleasePool, NSPoint, NSRect, NSSize};
    use gpui_wgpu::{WgpuRenderer, WgpuSurfaceConfig, wgpu};
    use objc::{class, msg_send, sel, sel_impl};
    use raw_window_handle::{
        AppKitWindowHandle, DisplayHandle, HandleError, HasDisplayHandle, HasWindowHandle,
        RawWindowHandle, WindowHandle,
    };
    use std::{cell::RefCell, ptr::NonNull, rc::Rc};

    #[link(name = "QuartzCore", kind = "framework")]
    unsafe extern "C" {}

    #[derive(Clone, Debug)]
    struct ViewHandle(usize);
    impl HasWindowHandle for ViewHandle {
        fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
            let raw = AppKitWindowHandle::new(NonNull::new(self.0 as *mut _).unwrap());
            Ok(unsafe { WindowHandle::borrow_raw(RawWindowHandle::AppKit(raw)) })
        }
    }
    impl HasDisplayHandle for ViewHandle {
        fn display_handle(&self) -> Result<DisplayHandle<'_>, HandleError> {
            Ok(DisplayHandle::appkit())
        }
    }

    pub fn run() -> anyhow::Result<()> {
        unsafe {
            let pool = NSAutoreleasePool::new(nil);
            NSApp();
            let frame = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(208.0, 212.0));
            let window = NSWindow::alloc(nil).initWithContentRect_styleMask_backing_defer_(
                frame,
                NSWindowStyleMask::NSBorderlessWindowMask,
                NSBackingStoreType::NSBackingStoreBuffered,
                false,
            );
            let view = NSView::alloc(nil).initWithFrame_(frame);
            window.setContentView_(view);
            let layer: id = msg_send![class!(CAMetalLayer), new];
            let _: () = msg_send![view, setWantsLayer: true];
            let _: () = msg_send![view, setLayer: layer];
            let handle = ViewHandle(view as usize);
            let context = Rc::new(RefCell::new(None));
            let mut renderer = WgpuRenderer::new_with_surface_target(
                context.clone(),
                &handle,
                wgpu::SurfaceTargetUnsafe::CoreAnimationLayer(layer.cast()),
                WgpuSurfaceConfig {
                    size: gpui::size(gpui::DevicePixels(208), gpui::DevicePixels(212)),
                    transparent: false,
                    preferred_present_mode: None,
                },
                None,
            )?;
            let mut scene = gpui::Scene::default();
            let bounds = gpui::Bounds::new(
                gpui::point(gpui::ScaledPixels(0.0), gpui::ScaledPixels(0.0)),
                gpui::size(gpui::ScaledPixels(208.0), gpui::ScaledPixels(212.0)),
            );
            scene.insert_primitive(gpui::Quad {
                bounds,
                content_mask: gpui::ContentMask { bounds },
                background: gpui::rgb(0xff0000).into(),
                ..Default::default()
            });
            scene.finish();
            assert!(renderer.draw(&scene), "initial frame must present");
            let rgba = renderer.render_to_rgba(&scene)?;
            assert_eq!(rgba.len(), 208 * 212 * 4);
            for pixel in rgba.chunks_exact(4) {
                assert_eq!(
                    pixel,
                    &[255, 0, 0, 255],
                    "readback must preserve RGBA channel order and row padding"
                );
            }
            renderer
                .update_drawable_size(gpui::size(gpui::DevicePixels(240), gpui::DevicePixels(240)));
            assert!(renderer.draw(&scene), "resized frame must present");
            let rgba = renderer.render_to_rgba(&scene)?;
            assert_eq!(rgba.len(), 240 * 240 * 4);
            assert_eq!(
                &rgba[rgba.len() - 4..],
                &[0, 0, 0, 0],
                "resized capture must preserve cleared pixels outside the scene"
            );
            renderer.destroy();
            drop(renderer);
            drop(context);
            let _: () = msg_send![view, setLayer: nil];
            let _: () = msg_send![layer, release];
            let _: () = msg_send![view, release];
            let _: () = msg_send![window, release];
            pool.drain();
        }
        println!(
            "PASS explicit CAMetalLayer GPUI renderer create, draw, RGBA capture, resize, teardown"
        );
        Ok(())
    }
}

#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    native::run()
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("This native surface smoke test requires macOS.");
}
