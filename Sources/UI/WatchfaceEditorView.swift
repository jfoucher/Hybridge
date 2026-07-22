import SwiftUI
import PhotosUI

enum EditorLayout {
    static func usesSideBySide(horizontalSizeClass: UserInterfaceSizeClass?,
                               verticalSizeClass: UserInterfaceSizeClass?,
                               availableWidth: CGFloat) -> Bool {
        verticalSizeClass == .compact
            || (horizontalSizeClass == .regular && availableWidth >= 700)
    }

    static func previewSide(paneSize: CGSize, sideBySide: Bool) -> CGFloat {
        let widthLimit = paneSize.width - 44
        let heightLimit = sideBySide ? paneSize.height - 104 : paneSize.height * 0.42
        return max(120, min(250, widthLimit, heightLimit))
    }
}

@MainActor
struct WatchfaceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State var design: WatchfaceDesign
    let onSave: (WatchfaceDesign) -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var selectedWidgetID: UUID?
    @State private var selectedTextID: UUID?
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    @State private var sourceImage: UIImage?
    @State private var sourcePNG: Data?
    @State private var previewRenderTask: Task<Void, Never>?
    @State private var backgroundRenderTask: Task<Void, Never>?
    @State private var backgroundRenderGeneration: UUID?
    /// Quantized, contrast-adjusted rendition of `sourceImage` shown live in
    /// the face preview (rebuilt when the photo or the contrast changes).
    @State private var adjustedPreview: UIImage?
    /// Contrast applied to an uploaded photo (mirrors `design.contrast`).
    @State private var contrast: Double = 1.0
    /// Solid background colour used when no photo is picked (mirrors
    /// `design.backgroundColorHex`).
    @State private var backgroundColor: Color = .black
    /// Alignment guide lines to draw while an element is being dragged (face
    /// coords, nil = none). Set by the handles' snap logic.
    @State private var activeGuides: (x: CGFloat?, y: CGFloat?)? = nil
    @State private var tool: EditorTool = .complications
    @State private var previewSide: CGFloat = 250

    enum EditorTool: Hashable { case photo, complications, text }

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = EditorLayout.usesSideBySide(
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass,
                availableWidth: geometry.size.width
            )
            let studioWidth = sideBySide
                ? min(420, max(280, geometry.size.width * 0.44))
                : geometry.size.width
            let faceSide = EditorLayout.previewSide(
                paneSize: CGSize(width: studioWidth, height: geometry.size.height),
                sideBySide: sideBySide
            )

            Group {
                if sideBySide {
                    HStack(spacing: 0) {
                        studio(faceSize: faceSide, showsGrabber: false)
                            .frame(width: studioWidth)
                        Rectangle().fill(Theme.line).frame(width: 1)
                        bottomSheet
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        studio(faceSize: faceSide, showsGrabber: true)
                        bottomSheet
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .onAppear { previewSide = faceSide }
            .onChange(of: faceSide) { _, newValue in previewSide = newValue }
        }
        .background(Theme.bg.ignoresSafeArea())
        .tint(Theme.accent)
        .onDisappear {
            previewRenderTask?.cancel()
            backgroundRenderTask?.cancel()
        }
    }

    // MARK: Dark studio (top half)

    private func studio(faceSize: CGFloat, showsGrabber: Bool) -> some View {
        VStack(spacing: 0) {
            if showsGrabber {
                Capsule().fill(.white.opacity(0.28))
                    .frame(width: 38, height: 5)
                    .padding(.top, 10).padding(.bottom, 12)
            } else {
                Spacer().frame(height: 16)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 16))
                    .foregroundStyle(Color(hex: 0xC9C3B4))
                Spacer()
                Text(design.name.isEmpty ? String(localized: "New Watchface") : design.name)
                    .font(Theme.serif(22))
                    .foregroundStyle(Color(hex: 0xF4F1EA))
                    .lineLimit(1)
                Spacer()
                Button("Save") { onSave(design); dismiss() }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xD8A94B))
                    .disabled(backgroundRenderGeneration != nil)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)

            facePreview(faceSize: faceSize)
                .padding(.bottom, showsGrabber ? 28 : 16)
        }
        .frame(maxWidth: .infinity, maxHeight: showsGrabber ? nil : .infinity)
        .background(Color(hex: 0x17150F).ignoresSafeArea(edges: .top))
    }

    // MARK: Light tool sheet (bottom half)

    private var bottomSheet: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                nameField

                ThemedSegmented(options: [(.photo, "Photo"), (.complications, "Complications"),
                                          (.text, "Text")],
                                selection: $tool)

                switch tool {
                case .photo:         photoTool
                case .complications: complicationsTool
                case .text:          textLayerList
                }

                Text("Drag any complication or text layer on the face to reposition it; pinch a photo to zoom. The background is dithered to the watch's 2-bit e-ink palette on install.")
                    .font(.system(size: 12)).foregroundStyle(Theme.sub).lineSpacing(2)
                    .padding(.horizontal, 2)
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 28)
        }
    }

    // MARK: Photo tool

    private var photoTool: some View {
        let pickerTitle = sourceImage == nil
            ? String(localized: "Choose background photo")
            : String(localized: "Change background photo")
        return VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                    Text(pickerTitle)
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1).background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card)))
            }
            .onChange(of: photoItem) { _, item in loadPhoto(item) }

            if sourceImage != nil {
                Text("Pinch to zoom and drag to reposition the photo on the face above.")
                    .font(.system(size: 12)).foregroundStyle(Theme.sub)

                HStack {
                    Text("Contrast").foregroundStyle(Theme.sub)
                    // Live preview follows every step; the costly 480px
                    // re-encode into backgroundPNG waits for the drag to end.
                    Slider(value: $contrast, in: 0.5...2.0, step: 0.05,
                           onEditingChanged: { editing in
                               if !editing { updateBackgroundPNG() }
                           })
                        .onChange(of: contrast) { _, _ in rebuildAdjustedPreview() }
                    Text(String(localized: "\(contrast.formatted(.number.precision(.fractionLength(2))))×"))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                .font(.system(size: 13))

                Button(role: .destructive) { removePhoto() } label: {
                    Label("Remove photo", systemImage: "trash")
                        .font(.system(size: 14))
                }
            } else {
                ColorPicker(selection: $backgroundColor, supportsOpacity: false) {
                    Text("Background colour").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
                .onChange(of: backgroundColor) { _, _ in applyBackgroundColor() }

                Text("With no photo, the face is filled with this colour, dithered to the watch's 2-bit grayscale on install.")
                    .font(.system(size: 12)).foregroundStyle(Theme.sub)
            }
        }
    }

    // MARK: Complications tool

    private var complicationsTool: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Add complication").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(design.widgets.count) / 4 slots").font(Theme.mono(12)).foregroundStyle(Theme.sub)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(WidgetCatalog.availableEntries) { entry in
                        complicationChip(entry)
                    }
                }
                .padding(.bottom, 4)
            }

            // Inline editor for the selected complication.
            if let id = selectedWidgetID, let widget = design.widgets.first(where: { $0.id == id }) {
                widgetRow(widget)
            } else if !design.widgets.isEmpty {
                Text("Tap an added complication (or its marker on the face) to edit its colour, ring and background.")
                    .font(.system(size: 12)).foregroundStyle(Theme.sub)
            }
        }
    }

    private func complicationChip(_ entry: WidgetCatalog.Entry) -> some View {
        let added = design.widgets.contains { $0.type == entry.type }
        return Button {
            if added {
                // Tapping a chip that's already on the face selects it for
                // editing (colour/ring/background) rather than removing it —
                // removal is the trash button in the inline editor below.
                selectedWidgetID = design.widgets.first { $0.type == entry.type }?.id
            } else if design.widgets.count < WidgetCatalog.maxComplications {
                addWidget(entry.type)
                selectedWidgetID = design.widgets.last?.id
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(added ? Theme.accent : Theme.card)
                        .overlay(added ? nil : Circle()
                            .strokeBorder(Theme.dashedStroke, style: StrokeStyle(lineWidth: 1.6, dash: [4, 3])))
                    Image(systemName: iconFor(entry.type))
                        .font(.system(size: 22))
                        .foregroundStyle(added ? .white : Theme.accent)
                }
                .frame(width: 66, height: 66)
                Text(added ? "\(entry.title) ✓" : entry.title)
                    .font(.system(size: 12, weight: added ? .semibold : .regular))
                    .foregroundStyle(added ? Theme.success : Theme.sub)
                    .lineLimit(1)
            }
            .frame(width: 74)
        }
        .buttonStyle(.plain)
        .disabled(!added && design.widgets.count >= WidgetCatalog.maxComplications)
        .opacity(!added && design.widgets.count >= WidgetCatalog.maxComplications ? 0.4 : 1)
    }

    private func iconFor(_ type: String) -> String {
        let t = type.lowercased()
        if t.contains("step") { return "figure.walk" }
        if t.contains("heart") || t.contains("hr") { return "heart.fill" }
        if t.contains("date") { return "calendar" }
        if t.contains("weather") { return "cloud" }
        if t.contains("batt") { return "battery.100" }
        if t.contains("tz") || t.contains("zone") { return "globe" }
        if t.contains("calor") || t.contains("active") { return "flame.fill" }
        if t.contains("custom") { return "textformat" }
        return "circle.grid.2x2"
    }

    // MARK: Name field

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.sub)
            TextField("Watchface name", text: $design.name)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }

    // MARK: Preview with draggable complications

    private func facePreview(faceSize: CGFloat) -> some View {
        ZStack {
            Group {
                // 1. Primary: Use sourceImage for live interactive editing
                if sourceImage != nil, let preview = adjustedPreview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(scale)
                        .offset(displayOffset(for: faceSize))
                        .gesture(imageAdjustmentGestures(previewSize: faceSize))
                
                // 2. Fallback: Display existing static background before sourceImage loads
                } else if let png = design.backgroundPNG,
                          let image = UIImage(data: png),
                          let preview = ImageEncoder.quantizedPreview(from: image) {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.black
                }
            }
            .frame(width: faceSize, height: faceSize)
            .clipShape(Circle())
            .contentShape(Circle())

            ForEach(design.widgets) { widget in
                WidgetHandle(widget: widgetBinding(widget.id, \.self, default: widget),
                             isSelected: selectedWidgetID == widget.id,
                             scale: faceSize / 240,
                             snap: snapCenter,
                             onGuides: { activeGuides = $0 },
                             onSelect: { selectedWidgetID = widget.id })
            }

            ForEach(design.textLayers) { layer in
                TextLayerHandle(layer: textBinding(layer.id, \.self, default: layer),
                                isSelected: selectedTextID == layer.id,
                                scale: faceSize / 240,
                                snap: snapCenter,
                                onGuides: { activeGuides = $0 },
                                onSelect: { selectedTextID = layer.id })
            }

            if let g = activeGuides {
                GuideLines(gx: g.x, gy: g.y, scale: faceSize / 240)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: faceSize, height: faceSize)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color(hex: 0xCBB98F), lineWidth: 4))
        .padding(7)
        .background(Circle().fill(Color(hex: 0x1C1A15)))
        .shadow(color: .black.opacity(0.6), radius: 22, y: 11)
        .onAppear {
            contrast = design.contrast ?? 1.0
            if let hex = design.backgroundColorHex {
                backgroundColor = Color(hex: hex)
            }
            // A solid-colour design stores its fill in backgroundPNG too, but
            // it must stay editable as a colour — only treat the stored PNG as
            // a photo when no solid colour was chosen.
            if sourceImage == nil, design.backgroundColorHex == nil,
               let png = design.backgroundPNG,
               let image = UIImage(data: png) {
                sourcePNG = png
                sourceImage = image
                rebuildAdjustedPreview()
            }
        }
    }

    /// Rebuild the quantized, contrast-adjusted preview shown on the face.
    private func rebuildAdjustedPreview() {
        previewRenderTask?.cancel()
        guard let sourcePNG else { adjustedPreview = nil; return }
        let contrast = contrast
        previewRenderTask = Task {
            do {
                let png = try await BoundedImageProcessor.preview(
                    sourcePNG: sourcePNG, contrast: contrast)
                try Task.checkCancellation()
                guard self.sourcePNG == sourcePNG, self.contrast == contrast else { return }
                adjustedPreview = UIImage(data: png)
            } catch is CancellationError {
                return
            } catch {
                ToastCenter.shared.error(error.localizedDescription)
            }
        }
    }

    /// Snap a proposed face-coordinate centre (0…240) to the face centre and
    /// to the x/y of every other element, so complications line up. Returns
    /// the snapped point plus any active guide-line coordinates. `excluding`
    /// keeps an element from snapping to itself.
    private func snapCenter(_ p: CGPoint, excluding id: UUID) -> (point: CGPoint, gx: CGFloat?, gy: CGFloat?) {
        let threshold: CGFloat = 5
        var xs: [CGFloat] = [120]   // face centre line
        var ys: [CGFloat] = [120]
        for w in design.widgets where w.id != id { xs.append(CGFloat(w.x)); ys.append(CGFloat(w.y)) }
        for t in design.textLayers where t.id != id { xs.append(CGFloat(t.x)); ys.append(CGFloat(t.y)) }
        var rx = p.x, ry = p.y
        var gx: CGFloat? = nil, gy: CGFloat? = nil
        if let n = xs.min(by: { abs($0 - p.x) < abs($1 - p.x) }), abs(n - p.x) <= threshold { rx = n; gx = n }
        if let n = ys.min(by: { abs($0 - p.y) < abs($1 - p.y) }), abs(n - p.y) <= threshold { ry = n; gy = n }
        return (CGPoint(x: rx, y: ry), gx, gy)
    }

    /// Compact ±1 px steppers for an element's X/Y — coarse-drag to get close,
    /// then nudge for exact placement. Values are in face pixels (0…240).
    private func nudgeControls(x: Binding<Int>, y: Binding<Int>, clamp: ClosedRange<Int>) -> some View {
        HStack(spacing: 18) {
            axisStepper("X", value: x, clamp: clamp)
            axisStepper("Y", value: y, clamp: clamp)
            Spacer()
        }
    }

    private func axisStepper(_ label: String, value: Binding<Int>, clamp: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Button {
                value.wrappedValue = max(clamp.lowerBound, value.wrappedValue - 1)
            } label: { Image(systemName: "minus.circle.fill").font(.system(size: 20)) }
            Text("\(value.wrappedValue)")
                .font(.system(size: 14, weight: .medium)).monospacedDigit()
                .frame(width: 34)
            Button {
                value.wrappedValue = min(clamp.upperBound, value.wrappedValue + 1)
            } label: { Image(systemName: "plus.circle.fill").font(.system(size: 20)) }
        }
        .buttonStyle(.plain)
        .tint(Theme.accent)
    }

    // Adjust image
    private func imageAdjustmentGestures(previewSize: CGFloat) -> some Gesture {
        SimultaneousGesture(
            // Zoom Gesture
            MagnificationGesture()
                .onChanged { value in
                    scale = lastScale * value
                }

                .onEnded { _ in
                    // Optional: Prevent shrinking smaller than the frame
                    if scale < 1.0 {
                        withAnimation(.spring()) {
                            scale = 1.0
                            lastScale = 1.0
                        }
                    } else {
                        lastScale = scale
                    }
                    
                    updateBackgroundPNG(previewSize: previewSize)
                },
            
            // Pan/Move Gesture
            DragGesture()
                .onChanged { value in
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width * 240 / previewSize,
                        height: lastOffset.height + value.translation.height * 240 / previewSize
                    )
                }
                .onEnded { _ in
                    lastOffset = offset
                    
                    updateBackgroundPNG(previewSize: previewSize)
                }
        )
    }

    
    // MARK: Widget management

    private var widgetList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Complications").font(.headline)
                Spacer()
                Menu {
                    ForEach(WidgetCatalog.availableEntries) { entry in
                        Button(entry.title) { addWidget(entry.type) }
                    }
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .disabled(design.widgets.count >= WidgetCatalog.maxComplications)
            }
            .padding(.horizontal)

            ForEach(design.widgets) { widget in
                widgetRow(widget)
            }
        }
    }

    /// Binding into `design.widgets` that looks the widget up by id on every
    /// access. ForEach element bindings are positional, so they crash with
    /// "Index out of range" when SwiftUI re-evaluates a row while the array
    /// is shrinking (add/remove); id lookup stays valid.
    private func widgetBinding<T>(_ id: UUID, _ keyPath: WritableKeyPath<WatchfaceWidget, T>,
                                  default fallback: T) -> Binding<T> {
        Binding(
            get: {
                guard let i = design.widgets.firstIndex(where: { $0.id == id }) else { return fallback }
                return design.widgets[i][keyPath: keyPath]
            },
            set: { newValue in
                guard let i = design.widgets.firstIndex(where: { $0.id == id }) else { return }
                design.widgets[i][keyPath: keyPath] = newValue
            }
        )
    }

    private func widgetRow(_ widget: WatchfaceWidget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(WidgetCatalog.title(for: widget.type))
                    .font(.subheadline.bold())
                Spacer()
                Button(role: .destructive) {
                    design.widgets.removeAll { $0.id == widget.id }
                } label: {
                    Image(systemName: "trash")
                }
            }
            Picker("Color", selection: widgetBinding(widget.id, \.color, default: 0)) {
                Text("White").tag(0)
                Text("Black").tag(1)
            }
            .pickerStyle(.segmented)
            if WidgetCatalog.supportsGoalRing(widget.type) {
                Toggle("Goal ring", isOn: Binding(
                    get: { design.widgets.first { $0.id == widget.id }?.wantsGoalRing ?? false },
                    set: { newValue in
                        guard let i = design.widgets.firstIndex(where: { $0.id == widget.id }) else { return }
                        design.widgets[i].goalRing = newValue
                    }
                ))
            }
            if WidgetCatalog.hasIcon(widget.type) {
                Toggle("Show icon", isOn: Binding(
                    get: { design.widgets.first { $0.id == widget.id }?.wantsIcon ?? true },
                    set: { newValue in
                        guard let i = design.widgets.firstIndex(where: { $0.id == widget.id }) else { return }
                        design.widgets[i].showIcon = newValue
                    }
                ))
            }
            Toggle("Solid background", isOn: Binding(
                get: { design.widgets.first { $0.id == widget.id }?.wantsSolidFill ?? false },
                set: { newValue in
                    guard let i = design.widgets.firstIndex(where: { $0.id == widget.id }) else { return }
                    design.widgets[i].solidFill = newValue
                }
            ))
            Picker("Ring", selection: widgetBinding(widget.id, \.background, default: "")) {
                ForEach(WidgetCatalog.backgrounds, id: \.name) { background in
                    Text(background.title).tag(background.name)
                }
            }
            nudgeControls(x: widgetBinding(widget.id, \.x, default: 120),
                          y: widgetBinding(widget.id, \.y, default: 120),
                          clamp: (WatchfaceWidget.size / 2)...(240 - WatchfaceWidget.size / 2))
                .padding(.top, 2)
            if widget.type == "widget2ndTZ" {
                Picker("Time zone", selection: widgetBinding(widget.id, \.tzName, default: nil)) {
                    Text("Pick a time zone…").tag(String?.none)
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { id in
                        Text(Self.timeZoneDisplayName(id)).tag(String?.some(id))
                    }
                }
                Text("The offset is baked in at install time — reinstall the face after DST changes.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if widget.type == "widgetCustom" {
                Text("Shows text pushed from the phone (Watchfaces → Custom widget text).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal)
    }

    private static func timeZoneDisplayName(_ identifier: String) -> String {
        TimeZone(identifier: identifier)?.localizedName(for: .generic, locale: .current)
            ?? identifier.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Text layers

    private static let fontFamilies = UIFont.familyNames.sorted()

    private var textLayerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Text").font(.headline)
                Spacer()
                Button {
                    let layer = WatchfaceTextLayer()
                    design.textLayers.append(layer)
                    selectedTextID = layer.id
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
            }
            .padding(.horizontal)

            ForEach(design.textLayers) { layer in
                textLayerRow(layer)
            }
        }
    }

    /// Same id-lookup binding as `widgetBinding`, for text layers.
    private func textBinding<T>(_ id: UUID, _ keyPath: WritableKeyPath<WatchfaceTextLayer, T>,
                                default fallback: T) -> Binding<T> {
        Binding(
            get: {
                guard let i = design.textLayers.firstIndex(where: { $0.id == id }) else { return fallback }
                return design.textLayers[i][keyPath: keyPath]
            },
            set: { newValue in
                guard let i = design.textLayers.firstIndex(where: { $0.id == id }) else { return }
                design.textLayers[i][keyPath: keyPath] = newValue
            }
        )
    }

    /// Number of layers already live-on-watch. There is no longer a fixed cap
    /// (the old GB engine's two-widget limit is gone with the monolithic
    /// customFace renderer); the real limit is the layout node budget, enforced
    /// at build time (CustomFaceLayout.maxNodes → WappError.tooManyElements).
    /// Each dynamic layer costs one node per character slot, so short values
    /// (HR, weekday) are cheap and long ones (steps, time) cost more.
    private var dynamicTextLayerCount: Int {
        design.textLayers.filter { $0.valueSource != nil }.count
    }

    private func valueSourceBinding(_ id: UUID) -> Binding<WatchfaceValueSource?> {
        Binding(
            get: { design.textLayers.first { $0.id == id }?.valueSource },
            set: { newValue in
                guard let i = design.textLayers.firstIndex(where: { $0.id == id }) else { return }
                design.textLayers[i].valueSource = newValue
            }
        )
    }

    private func textLayerRow(_ layer: WatchfaceTextLayer) -> some View {
        let isDynamic = layer.valueSource != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let source = layer.valueSource {
                    Text(source.sampleText)
                        .font(Font(layer.uiFont(scale: 1) as CTFont))
                        .foregroundStyle(Color(uiColor: layer.uiColor))
                        .padding(.vertical, 4)
                } else {
                    TextField("Text", text: textBinding(layer.id, \.text, default: ""))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                Button(role: .destructive) {
                    design.textLayers.removeAll { $0.id == layer.id }
                } label: {
                    Image(systemName: "trash")
                }
            }
            Picker("Value", selection: valueSourceBinding(layer.id)) {
                Text("Static text").tag(WatchfaceValueSource?.none)
                ForEach(WatchfaceValueSource.availableCases) { source in
                    Text(source.title).tag(WatchfaceValueSource?.some(source))
                }
            }
            if isDynamic {
                Text("Filled in live by the watch — never leaves the phone as text.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Font", selection: textBinding(layer.id, \.fontFamily, default: "")) {
                    Text("System").tag("")
                    ForEach(Self.fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Spacer()
                Toggle("Bold", isOn: textBinding(layer.id, \.bold, default: false))
                    .fixedSize()
            }
            HStack {
                Text("Size").foregroundStyle(.secondary)
                Slider(value: textBinding(layer.id, \.fontSize, default: 24), in: 8...96, step: 1)
                Text("\(Int(layer.fontSize)) px")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            HStack {
                Text("Angle").foregroundStyle(.secondary)
                Slider(value: textBinding(layer.id, \.rotation, default: 0), in: -180...180, step: 1)
                    .disabled(isDynamic)
                Text("\(Int(layer.rotation))°")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            if isDynamic {
                Text("Live values are always drawn upright.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Picker("Shade", selection: textBinding(layer.id, \.shade, default: 3)) {
                Text("Black").tag(0)
                Text("Dark").tag(1)
                Text("Light").tag(2)
                Text("White").tag(3)
            }
            .pickerStyle(.segmented)
            nudgeControls(x: textBinding(layer.id, \.x, default: 120),
                          y: textBinding(layer.id, \.y, default: 120),
                          clamp: 0...240)
                .padding(.top, 2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal)
    }

    private func addWidget(_ type: String) {
        // Default positions: top, bottom, left, right of center.
        let spots = [(120, 58), (120, 182), (58, 120), (182, 120)]
        let spot = spots[min(design.widgets.count, spots.count - 1)]
        design.widgets.append(WatchfaceWidget(type: type, x: spot.0, y: spot.1,
                                              color: 0, background: "widget_bg_thin_circle"))
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let transfer = try await item.loadTransferable(
                    type: BoundedPhotoTransfer.self),
                      let rawImage = UIImage(data: transfer.pngData) else {
                    throw BoundedImageImportError.invalidImage
                }
                let image = rawImage.fixingOrientation()
                
                await MainActor.run {
                    // Reset gesture states on new photo load
                    scale = 1.0
                    lastScale = 1.0
                    offset = .zero
                    lastOffset = .zero
                    
                    // Store the raw image for editing gestures
                    self.sourcePNG = transfer.pngData
                    self.sourceImage = image
                    rebuildAdjustedPreview()

                    // Immediately generate an initial centered 480x480 crop
                    updateBackgroundPNG()
                }
            } catch {
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }
    
    private func updateBackgroundPNG(previewSize: CGFloat? = nil) {
        backgroundRenderTask?.cancel()
        guard let sourcePNG else { return }
        let generation = UUID()
        backgroundRenderGeneration = generation
        let side = previewSize ?? previewSide
        let contrast = contrast
        let scale = scale
        let renderedOffset = displayOffset(for: side)
        backgroundRenderTask = Task {
            defer {
                if backgroundRenderGeneration == generation {
                    backgroundRenderGeneration = nil
                }
            }
            do {
                let png = try await BoundedImageProcessor.background(
                    sourcePNG: sourcePNG, contrast: contrast, scale: scale,
                    offset: renderedOffset, previewSize: side)
                try Task.checkCancellation()
                guard self.sourcePNG == sourcePNG else { return }
                design.contrast = contrast
                design.backgroundColorHex = nil
                design.backgroundPNG = png
            } catch is CancellationError {
                return
            } catch {
                ToastCenter.shared.error(error.localizedDescription)
            }
        }
    }

    /// Photo offsets are stored in the face's 240-point coordinate space, so
    /// rotating or resizing the editor does not alter the crop.
    private func displayOffset(for previewSize: CGFloat) -> CGSize {
        CGSize(width: offset.width * previewSize / 240,
               height: offset.height * previewSize / 240)
    }

    /// Bake the chosen solid colour into a 480×480 background (no photo).
    private func applyBackgroundColor() {
        previewRenderTask?.cancel()
        backgroundRenderTask?.cancel()
        backgroundRenderGeneration = nil
        let hex = backgroundColor.rgbHex
        design.backgroundColorHex = hex
        design.contrast = nil

        let side: CGFloat = 480
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let image = renderer.image { context in
            UIColor(backgroundColor).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        design.backgroundPNG = image.pngData()
    }

    /// Drop the uploaded photo and fall back to the solid-colour background.
    private func removePhoto() {
        previewRenderTask?.cancel()
        backgroundRenderTask?.cancel()
        backgroundRenderGeneration = nil
        sourcePNG = nil
        sourceImage = nil
        adjustedPreview = nil
        photoItem = nil
        scale = 1.0; lastScale = 1.0
        offset = .zero; lastOffset = .zero
        contrast = 1.0
        applyBackgroundColor()
    }

    private func resize(_ image: UIImage, to side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
}

/// Snap a proposed face-coordinate centre to alignment targets; returns the
/// snapped point and any active guide-line coordinates (face coords).
private typealias FaceSnapper = (_ proposed: CGPoint, _ excluding: UUID)
    -> (point: CGPoint, gx: CGFloat?, gy: CGFloat?)

/// Marks a dragged element's true (snapped) centre — the element itself floats
/// above the fingertip, this stays under it so the target is always visible.
private struct DragCrosshair: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white, lineWidth: 1.5).frame(width: 16, height: 16)
            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
        }
        .shadow(color: .black.opacity(0.5), radius: 1)
    }
}

/// Live "x, y" badge shown next to a dragged element.
private struct DragReadout: View {
    let x: Int
    let y: Int
    var body: some View {
        Text("\(x), \(y)")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.78)))
    }
}

/// Centre / alignment guide lines drawn across the face during a drag.
private struct GuideLines: View {
    let gx: CGFloat?
    let gy: CGFloat?
    let scale: CGFloat
    var body: some View {
        let side = 240 * scale
        ZStack {
            if let gx {
                Rectangle().fill(Color.accentColor.opacity(0.85))
                    .frame(width: 1, height: side)
                    .position(x: gx * scale, y: side / 2)
            }
            if let gy {
                Rectangle().fill(Color.accentColor.opacity(0.85))
                    .frame(width: side, height: 1)
                    .position(x: side / 2, y: gy * scale)
            }
        }
        .frame(width: side, height: side)
    }
}

/// Draggable complication marker on the face preview. While dragging, the
/// marker lifts above the fingertip (so it's never hidden), a crosshair pins
/// its true centre, a live x/y badge shows the coordinates, and it snaps to
/// the face centre / other elements via `snap`.
private struct WidgetHandle: View {
    @Binding var widget: WatchfaceWidget
    let isSelected: Bool
    let scale: CGFloat
    let snap: FaceSnapper
    let onGuides: ((x: CGFloat?, y: CGFloat?)?) -> Void
    let onSelect: () -> Void

    @GestureState private var dragTranslation: CGSize? = nil

    /// How far (points) the marker floats above the fingertip while dragging.
    private static let liftPoints: CGFloat = 54

    var body: some View {
        let side = 240 * scale
        let diameter = CGFloat(WatchfaceWidget.size) * scale
        let dragging = dragTranslation != nil
        // The marker floats a fixed distance above the finger so it isn't
        // hidden, and it *commits at that floated position* — so it stays
        // exactly where you see it on release (the finger sits just below).
        let liftFace = (dragging ? Self.liftPoints : 0) / scale
        let raw = CGPoint(x: CGFloat(widget.x) + (dragTranslation?.width ?? 0) / scale,
                          y: CGFloat(widget.y) + (dragTranslation?.height ?? 0) / scale - liftFace)
        let center = dragging ? snap(raw, widget.id).point
                              : CGPoint(x: CGFloat(widget.x), y: CGFloat(widget.y))
        let px = center.x * scale
        let py = center.y * scale

        return ZStack {
            marker(diameter: diameter)
                .contentShape(Circle())
                .onTapGesture { onSelect() }
                .gesture(dragGesture)
                .position(x: px, y: py)

            if dragging {
                DragCrosshair().allowsHitTesting(false).position(x: px, y: py)
                DragReadout(x: Int(center.x.rounded()), y: Int(center.y.rounded()))
                    .allowsHitTesting(false)
                    .position(x: min(max(px, 26), side - 26),
                              y: max(14, py - diameter / 2 - 12))
            }
        }
        .frame(width: side, height: side)
        .onChange(of: dragging) { _, d in if !d { onGuides(nil) } }
    }

    private func marker(diameter: CGFloat) -> some View {
        Circle()
            .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.8),
                          style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            .background(Circle().fill((widget.color == 0 ? Color.black : Color.white).opacity(0.35)))
            .overlay(
                Text(WidgetCatalog.title(for: widget.type))
                    .font(.system(size: 9))
                    .foregroundStyle(widget.color == 0 ? .white : .black)
                    .multilineTextAlignment(.center)
            )
            .frame(width: diameter, height: diameter)
    }

    private var dragGesture: some Gesture {
        // Measure in the global space: the marker lifts above the finger while
        // dragging, so a .local space (which moves with the marker) would feed
        // its own movement back into the translation and oscillate.
        DragGesture(coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in state = value.translation }
            .onChanged { value in
                let raw = CGPoint(x: CGFloat(widget.x) + value.translation.width / scale,
                                  y: CGFloat(widget.y) + value.translation.height / scale - Self.liftPoints / scale)
                let r = snap(raw, widget.id)
                onGuides((x: r.gx, y: r.gy))
            }
            .onEnded { value in
                let raw = CGPoint(x: CGFloat(widget.x) + value.translation.width / scale,
                                  y: CGFloat(widget.y) + value.translation.height / scale - Self.liftPoints / scale)
                let p = snap(raw, widget.id).point
                let half = CGFloat(WatchfaceWidget.size) / 2
                widget.x = Int(min(max(p.x, half), 240 - half).rounded())
                widget.y = Int(min(max(p.y, half), 240 - half).rounded())
                onGuides(nil)
            }
    }
}

/// Draggable text layer on the face preview. Shows the layer with its real
/// font/shade/rotation; the baked result only differs by 2bpp quantization
/// of the antialiased edges. Same lift/crosshair/snap treatment as WidgetHandle.
private struct TextLayerHandle: View {
    @Binding var layer: WatchfaceTextLayer
    let isSelected: Bool
    let scale: CGFloat
    let snap: FaceSnapper
    let onGuides: ((x: CGFloat?, y: CGFloat?)?) -> Void
    let onSelect: () -> Void

    @GestureState private var dragTranslation: CGSize? = nil

    /// How far (points) the text floats above the fingertip while dragging.
    private static let liftPoints: CGFloat = 54

    var body: some View {
        let side = 240 * scale
        let dragging = dragTranslation != nil
        // Floats above the finger and commits at that floated position — see
        // WidgetHandle for why.
        let liftFace = (dragging ? Self.liftPoints : 0) / scale
        let raw = CGPoint(x: CGFloat(layer.x) + (dragTranslation?.width ?? 0) / scale,
                          y: CGFloat(layer.y) + (dragTranslation?.height ?? 0) / scale - liftFace)
        let center = dragging ? snap(raw, layer.id).point
                              : CGPoint(x: CGFloat(layer.x), y: CGFloat(layer.y))
        let px = center.x * scale
        let py = center.y * scale

        return ZStack {
            marker
                .rotationEffect(.degrees(layer.valueSource == nil ? layer.rotation : 0))
                .contentShape(Rectangle())
                .onTapGesture { onSelect() }
                .gesture(dragGesture)
                .position(x: px, y: py)

            if dragging {
                DragCrosshair().allowsHitTesting(false).position(x: px, y: py)
                DragReadout(x: Int(center.x.rounded()), y: Int(center.y.rounded()))
                    .allowsHitTesting(false)
                    .position(x: min(max(px, 26), side - 26),
                              y: max(14, py - CGFloat(layer.fontSize) * scale / 2 - 12))
            }
        }
        .frame(width: side, height: side)
        .onChange(of: dragging) { _, d in if !d { onGuides(nil) } }
    }

    private var marker: some View {
        Text(layer.valueSource?.sampleText
             ?? (layer.text.isEmpty ? String(localized: "Text") : layer.text))
            .font(Font(layer.uiFont(scale: scale) as CTFont))
            .foregroundStyle(Color(uiColor: layer.uiColor))
            .opacity(layer.text.isEmpty ? 0.3 : 1)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.25),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }

    private var dragGesture: some Gesture {
        // Global space: the marker lifts above the finger, so a .local space
        // (which moves with the marker) would oscillate — see WidgetHandle.
        DragGesture(coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in state = value.translation }
            .onChanged { value in
                let raw = CGPoint(x: CGFloat(layer.x) + value.translation.width / scale,
                                  y: CGFloat(layer.y) + value.translation.height / scale - Self.liftPoints / scale)
                let r = snap(raw, layer.id)
                onGuides((x: r.gx, y: r.gy))
            }
            .onEnded { value in
                let raw = CGPoint(x: CGFloat(layer.x) + value.translation.width / scale,
                                  y: CGFloat(layer.y) + value.translation.height / scale - Self.liftPoints / scale)
                let p = snap(raw, layer.id).point
                // Center stays on the face; the text may overhang.
                layer.x = Int(min(max(p.x, 0), 240).rounded())
                layer.y = Int(min(max(p.y, 0), 240).rounded())
                onGuides(nil)
            }
    }
}

extension UIImage {
    func fixingOrientation() -> UIImage {
        // If it's already upright, no need to do anything
        guard imageOrientation != .up else { return self }
        
        let format = UIGraphicsImageRendererFormat()
        format.scale = self.scale
        let renderer = UIGraphicsImageRenderer(size: self.size, format: format)
        
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: self.size))
        }
    }
}
