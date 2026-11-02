# TapDone 图标

当前使用 v2：蓝色圆角底板、米白色卡通侧视按键、左高右低的倾斜造型和五条实心触发短线。键帽短厚，底座贴近键帽，强调轻点即响应。

- `icon-concept-v2.png`：用户确认的应用图标与菜单栏设计预览。
- `app-icon-v2.png`：当前透明背景母版，用于导出应用图标。
- `../../TapDone/Resources/Assets.xcassets/AppIcon.appiconset/`：macOS 16–1024 像素图标。
- `../../TapDone/Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.svg`：当前按键版单色矢量轮廓，使用 template 渲染适应菜单栏深浅外观。
- `icon-concept-v1.png`、`app-icon-v1.png`：旧版小精灵设计稿和母版，保留供追溯，不再用于应用。

应用图像通过内置 image_gen 从已确认的设计稿整理为透明 PNG；菜单栏为手工绘制的同造型 SVG。透明母版编辑提示词：

> Production asset extraction from the approved design sheet. Output ONLY the blue rounded-square application icon at the top as a square PNG with true transparent exterior. Preserve the compact ivory cartoon keycap side profile, thick navy outline, closely attached navy base with a narrow blue slit, left-high right-low clockwise tilt, and exactly five solid rounded activation rays. Preserve proportions and colors. Remove menu bar mockups, enlarged glyph and white exterior. Center the tile at 82 percent of canvas width with equal transparent margins. No redesign, text or exterior shadow.

尺寸变体由 `sips` 从透明母版缩放导出。修改后保留 macOS appiconset 的完整 size/scale 组合。

仓库首页 README 直接引用 `AppIcon.appiconset/icon_128x128@2x.png`，不维护单独的展示副本。后续更换图标时同步更新整套 appiconset，首页图标会随之更新；若调整资源路径，也需更新 README 的引用。
