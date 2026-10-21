# Skeuomorphic app design

Version 1.0 · 2026-10-03 · Gino's shared app design standard

Build every visible detail as a piece of work worth putting in a résumé showreel. The signature is a useful object made tangible: sealing wax on paper, an optical lens over evidence, a book that holds knowledge, a toolbox that holds commands. The icon should explain the product before the name is read.

This standard defines the shared craft across the collection. Each app keeps its own metaphor, colours and personality. Existing product design documents remain authoritative for platform components, interaction behaviour and tokens; this document adds the shared material and artwork discipline. Changes to those product decisions must be made explicitly in their own documentation.

## 1. Begin with the product

Write a one-sentence brief before drawing: **This app helps [person] do [job], represented by [physical object].** Choose an object with a clear relationship to that job.

Record five decisions beside the artwork:

| Decision | What to specify |
|---|---|
| Meaning | The product action the object represents |
| Silhouette | One shape recognisable at Dock and browser size |
| Materials | One dominant material and at most two supporting materials |
| Colour | One recognisable product colour with neutral support |
| Signature detail | The one detail worth noticing at large size |

The collection is related through craft, lighting and optical weight. Give each app its own object. A recognisable existing portrait, wordmark or symbol stays an identity decision; changing it requires a deliberate product decision rather than an incidental asset replacement.

## 2. Make the material believable

Use one broad light high to the left, with restrained fill that reveals dark surfaces. Highlights, bevels, reflections and cast shadows must agree with that light. Ground each raised part with a small contact shadow. Keep enough light in a dark icon for its silhouette to survive a dark background.

| Material | Evidence that makes it convincing |
|---|---|
| Wax | Uneven pooled edge, soft depth, matte pressed face, glossier rim, warmth through thin areas |
| Paper and cloth | Fine fibres or weave, meaningful folds and binding, broad diffuse light |
| Enamel and ceramic | Smooth glaze, soft edge reflections, a body with thickness |
| Metal | Directional brushing or a controlled polished highlight; distinct edges |
| Glass and stone | Refraction or subtle internal depth, a clear silhouette, restrained reflected colour |

Texture supports the object. It should disappear gracefully as the asset gets smaller. Wear should explain use, not cover the image in random scratches. Every inset, seam and fastening should make construction sense.

## 3. Compose for recognition

Use one dominant object and one focal point. Start with a straight-on or nearly straight-on view; a slight tilt may reveal useful thickness. Keep the visual centre stable and the subject large enough to recognise.

For standalone transparent review and Dock artwork, begin around 82–88% of the canvas width, then balance optically against adjacent icons. Tall handles and unusual silhouettes need individual treatment. Platform-specific masks, safe areas and opaque store submissions take precedence over this review-canvas starting point.

Leave deliberate space at the edges. Inspect the alpha against white, near-black and a checkerboard for fringes, stray pixels, paper flakes and clipped shadows. Bake object lighting once; a consumer should not add another heavy shadow or a second frame over an already rendered icon.

Letters and Japanese characters may be part of an established identity. Verify the character, shape and meaning. Use a simpler small-size mark when its strokes collapse. Product names, captions and decorative microtext belong outside the icon.

## 4. Design the small sizes

Review at the actual intended sizes, including 16, 32, 48, 64, 128 and 256 px. A large render is only the source, not proof that the small icon works.

- At 16–32 px, preserve the main silhouette, colour and one strong symbol. Remove detail that becomes noise.
- At 48–64 px, the object and its material should still read without enlargement.
- At 128–256 px, introduce enough texture and construction detail to reward attention.
- At full size, edges, lettering and lighting must withstand close inspection.

Use a separately authored small-size variant when simple resampling loses the identity. Keep native renderers that already do this well. Show the small versions beside the master in the review sheet and document which source supplies each size.

## 5. Carry the identity into the app

Let the icon be the richest object. Navigation, forms, tables and reading surfaces should stay calm and easy to use. Carry the identity through the app's existing accent, one meaningful material treatment and an occasional authored illustration.

Use the platform's established controls, layout grammar and typography. Preserve keyboard behaviour, focus, scrolling and accessibility. Reuse the app's design tokens; record any new material palette where it is used. Dense terminal interfaces should express the identity with a clear wordmark and restrained colour while keeping output legible.

Choose one signature moment per surface: a seal resolving, a card arriving, a precise selection transition. Motion should explain an action and settle quickly. Honour reduced motion with a useful static state. The object should feel crafted even with animation disabled.

## 6. Make every state usable

Review light and dark themes, desktop and narrow screens, keyboard focus, hover, pressed, disabled, loading, empty, error and long content states where the surface supports them. On the web, preserve useful behaviour with JavaScript disabled when that is part of the product contract.

Normal UI text must meet at least 4.5:1 contrast; qualifying large text may use 3:1. Required control and state indicators must meet 3:1 against adjacent colours. Check text over the actual material or gradient, including its lowest-contrast area. These requirements concern usable UI, not a demand that every decorative highlight meet the same ratio. See the [W3C text contrast guidance](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html) and [non-text contrast guidance](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html).

Give functional controls accessible names and visible focus. A decorative icon beside a visible app name should not repeat that name to a screen reader. If artwork itself is a link, give the link a useful name. State and severity need a label or shape as well as colour.

## 7. Keep an editable source and a small runtime asset

Store the source and provenance with the repo's brand assets. Preserve a procedural renderer, model or layered source when one exists. For generated artwork, retain the original master, prompt, reference roles and generation method. Identify a reconstructed brief honestly. Keep discarded explorations separate from selected assets.

Use the existing asset layout where practical. A typical brand pack includes:

| Asset | Purpose |
|---|---|
| Original master | Full-resolution source, with alpha preserved where appropriate |
| README/UI image | A modest PNG or WebP sized for its actual display |
| Browser icon | Small PNG or multi-size ICO with checked entries |
| Native app variants | The platform's required catalog, sizes and appearance variants |
| Brand README | Metaphor, material choices, provenance and export procedure |

The current collection exports PNG at 16, 32, 48, 64, 128, 180, 192, 256, 512 and 1024 px, a 256 px WebP and a 16/32/48 ICO. These are delivery conveniences, not replacements for a platform's own submission requirements. Consult the current [Apple app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons) when packaging a native app.

Ship only the sizes the runtime needs. Serve artwork locally, set intrinsic dimensions to avoid layout shift, and keep the product's CSP intact. Prefer a direct image file when an embedded image in SVG would complicate CSP or rendering. Verify nested routes, deployment prefixes, build inclusion and cache invalidation. A README preview, app header, browser icon and portfolio listing should use the same selected identity.

## 8. Review one app at a time

1. Read the product README and existing design guide. Inspect the current icon in its real context.
2. Write the brief and choose the object, materials and silhouette.
3. Make the master, then inspect the construction and identity before exporting.
4. Inspect real-size variants on light, dark and alpha backgrounds; simplify or rerender weak small sizes.
5. Integrate the selected assets into the real app, README and applicable portfolio surfaces.
6. Inspect the affected screens and states, then run the checks appropriate to the actual change.
7. Record the asset source, export procedure and verification evidence. Commit and publish through the repository's existing release workflow.

Treat source generation, export validation, browser/native visual review and production rollout as separate facts. If one is unverified, say which. A successful build cannot certify visual quality, and a published design document does not mean an artwork branch has been merged.

## 9. Maintain the collection

This version is copied identically to each repository at `docs/design/APP_DESIGN.md`. Each root `DESIGN.md` links here and retains its app-specific decisions. The local authoring copy lives with the icon collection; update the version and redistribute it when the shared standard changes. Keep product-specific exceptions in the product's own design guide instead of silently changing a shared copy.

Public repositories contain only their own approved identity and already-public material. Keep private app inventories, internal source paths, credentials and unpublished product details out of public documentation and artwork packs.

The standard is met when the object tells the truth about the app, its material survives scrutiny, its small form is recognisable, and its integration makes the product easier to understand.
