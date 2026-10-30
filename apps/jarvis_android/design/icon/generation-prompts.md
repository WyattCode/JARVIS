# 原始图标精修记录

工具：内置 image_gen；以原始 jarvis_brand.png 编辑，保留透明 alpha。没有使用 CLI/API fallback。

## 夜间前景

Use case: precise-object-edit. Asset type: premium Android launcher icon foreground for Jarvis AI assistant, square 1024x1024 transparent PNG. Image 1 is the original icon and the exact identity to preserve: a luminous spherical energy core with swirling cyan/ivory light ribbons, encircled by TWO intersecting elliptical orbital rings, one ice blue and one champagne gold, diagonally crossing around the core. Refine this original comprehensively, do not replace its concept with a letter, monogram, generic sparkle or new logo. Improve optical balance and sculptural depth, polished continuous orbital geometry, clear front/back occlusion, rounded clean silhouettes, restrained premium materials. Simplify the tiny busy sparks/beads/filaments so it stays beautifully legible at 48px; retain a few broad graceful sweeping internal light ribbons that imply a living intelligence. Reduce central blown-out white glare so the sphere has visible blue depth; retain luminous cyan rim and tasteful champagne-gold accent, bright science fiction rather than gloomy. Balanced, centered optical mass with generous clean transparent margins, whole design including orbit rings within roughly 78% of image width/height. NO words or letters, no stars outside the icon, no extra planets, no border, no squircle/container, no drop-shadow rectangle, no black painted pixels in background. Actual transparent alpha outside the subject; this foreground will be placed on pure black by Android. Keep the original recognizable, make it much more refined and quieter, not a different identity.

## 日间前景

Use case: precise-object-edit. Image 1 is the final NIGHT foreground icon of Jarvis, and must remain geometrically the SAME icon. Create the matching DAY foreground version by changing ONLY its materials and lighting for a pale porcelain/light ivory launcher background. Lock exact shape, ring inclinations, object scale, optical center, sphere silhouette, relative positions of the blue and gold rings and their few bead highlights, and all transparent margins. Preserve this recognizable original central flowing energy sphere and two crossing blue/gold orbital rings. For DAY: slightly deeper and clearer blue/teal sphere edges and internal luminous ribbons, satin champagne-gold rings with defined edges rather than blown-out light, controlled pearl-white core with substantially reduced bloom, fewer incidental pinprick sparkles. Keep the image bright, premium and alive, not dark. The two variants must look like ONE icon in two lighting conditions; do not invent a new composition. Real transparent alpha outside the complete subject, NO painted background, NO container, NO letters, NO words, no extra stars or decorative props. Square PNG, full uncut subject, original frame and scale unchanged.

## 导出

原图位于本目录 jarvis-day-master.png、jarvis-night-master.png；tools/export_icon.dart 只做尺寸与背景导出，不做内容修饰。
