# TapDone 图标 v1

当前采用蓝色圆角底板、米白色滑行小精灵和双椭圆眼睛。此版作为暂用方案，后续继续调整。

- `icon-concept-v1.png`：用户选定的概念预览原图。
- `app-icon-v1.png`：用于导出应用图标的透明背景母版。
- `../../TapDone/Resources/Assets.xcassets/AppIcon.appiconset/`：macOS 16–1024 像素图标，已配置到应用 target。
- `../../TapDone/Resources/Assets.xcassets/MenuBarIcon.imageset/`：手工绘制的简化 SVG 轮廓，使用 template 渲染适应菜单栏深浅外观。

图像使用内置 image_gen 生成。透明母版的编辑提示词：

> Prepare this EXACT approved app icon as a production asset. Preserve the blue rounded square and ivory sprite with two dark oval eyes exactly, including silhouette, orientation, colors and proportions. Remove ONLY the exterior white presentation background, replacing it with true transparency. Enlarge the icon tile proportionately to occupy 82 percent of the square canvas width, centered horizontally and vertically, leaving equal transparent margins. No redesign, no new shapes, no text, no shadows outside the tile. Output square transparent PNG.

尺寸变体由 `sips` 从透明母版缩放导出。修改后保留 macOS appiconset 的完整 size/scale 组合。

仓库首页 README 直接引用 `AppIcon.appiconset/icon_128x128@2x.png`，不维护单独的展示副本。后续更换图标时同步更新整套 appiconset，首页图标会随之更新；若调整资源路径，也需更新 README 的引用。
