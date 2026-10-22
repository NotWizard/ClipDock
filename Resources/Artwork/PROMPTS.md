# ClipDock icon generation prompts

Generated with the built-in image_gen tool. The shipping PNG is the unmodified generated raster; Scripts/make-icon.swift only resamples it into native icon sizes with optical padding. Menu-bar artwork is separately drawn as template PDF line art from the same folded-card and dock silhouette.

## Initial generation

Use case: logo-brand.
Asset type: production macOS application icon for ClipDock, a native clipboard-history utility.
Create one exceptionally polished, original icon master, square 1024 by 1024. Show a small stack of two captured ivory-white cards seated in an open graphite docking tray, a clear memorable silhouette expressing saved copies returning to a dock. The front card has a clean folded upper-right corner, gently rounded edges and only two short recessed content strokes. The rear card is subtly offset upward and left to express clipboard history. Remove the old office-clipboard top clip; the metaphor is captured digital cards, not a clipboard board.
Art direction: premium macOS icon craftsmanship, tactile sculpted depth and precise bevels, satin anodized graphite metal for the low open-U tray, warm ivory paper/ceramic cards. Restrained material realism with soft top-left studio light, credible contact shadows, fine edge highlights and calm depth; no toy-like thick plastic or cartoon outlines.
Keep continuity with ClipDock's warm coral/peach and dark ink identity: a softly shaded coral-to-peach rounded-square icon tile, ivory cards, deep graphite dock. Compose the symbol large and balanced, immediately recognizable at 32 pixels. A near-frontal view with only very mild perspective, strong uncluttered silhouette and generous separation of parts.
The rounded-square tile occupies about 84 percent of the canvas with even optical margins. Genuine transparent alpha outside the rounded-square tile; preserve clean smooth alpha edges, no white backdrop, no checkerboard painted into the image. No additional outer frame, no presentation board, no captions, no typography, no letters, no watermark, no extra objects. Output a single finished icon, not variants or a mockup.

## Alpha refinement

Reference: the initial generated image.

Edit this app icon only to make its alpha boundary production-ready. Preserve the exact design, coral/peach tile, ivory folded cards, graphite docking tray, materials, lighting, proportions and details inside the tile. Remove ALL stray yellow/red speckles and detached pixels outside the rounded-square tile. The surrounding canvas must be completely transparent alpha, including the entire top margin and corners. Give the rounded-square tile clean smoothly antialiased edges with no colored fringe or exterior glow. Recenter the unchanged icon with an even transparent margin so the tile occupies about 84% of a square canvas, suitable for a macOS app icon. Keep all internal image quality and tactile depth. Do not add objects, text, symbols, frames, or a visible background. Output one square finished transparent PNG.
