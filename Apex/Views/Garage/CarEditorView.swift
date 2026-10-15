import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

/// Text-based copy of a car, so Cancel leaves the model untouched.
struct CarDraft {
    var nickname = ""
    var make = ""
    var modelName = ""
    var year = ""
    var plate = ""
    var power = ""
    var torque = ""
    var weight = ""
    var displacement = ""
    var zeroToHundred = ""
    var topSpeed = ""
    var consumption = ""
    var tankSize = ""
    var odometer = ""
    var drivetrain: Drivetrain = .rwd
    var transmission: Transmission = .manual
    var fuelType: FuelType = .e10

    init(car: Car) {
        nickname = car.nickname
        make = car.make
        modelName = car.modelName
        year = car.year.map(String.init) ?? ""
        plate = car.plate
        power = car.powerPS.map(String.init) ?? ""
        torque = car.torqueNm.map(String.init) ?? ""
        weight = car.weightKg.map(String.init) ?? ""
        displacement = car.displacementCcm.map(String.init) ?? ""
        zeroToHundred = car.zeroToHundredSpec.map { Fmt.number($0, digits: 1) } ?? ""
        topSpeed = car.topSpeedSpec.map(String.init) ?? ""
        consumption = car.consumption.map { Fmt.number($0, digits: 1) } ?? ""
        tankSize = car.tankSize.map { Fmt.number($0, digits: 0) } ?? ""
        odometer = car.odometerStart.map { String(Int($0)) } ?? ""
        drivetrain = car.drivetrain
        transmission = car.transmission
        fuelType = car.fuelType
    }

    func apply(to car: Car) {
        car.nickname = nickname.trimmingCharacters(in: .whitespaces)
        car.make = make.trimmingCharacters(in: .whitespaces)
        car.modelName = modelName.trimmingCharacters(in: .whitespaces)
        car.year = Self.int(year)
        car.plate = plate.trimmingCharacters(in: .whitespaces).uppercased()
        car.powerPS = Self.int(power)
        car.torqueNm = Self.int(torque)
        car.weightKg = Self.int(weight)
        car.displacementCcm = Self.int(displacement)
        car.zeroToHundredSpec = Self.double(zeroToHundred)
        car.topSpeedSpec = Self.int(topSpeed)
        car.consumption = Self.double(consumption)
        car.tankSize = Self.double(tankSize)
        car.odometerStart = Self.double(odometer)
        car.drivetrain = drivetrain
        car.transmission = transmission
        car.fuelType = fuelType
    }

    static func int(_ text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    static func double(_ text: String) -> Double? {
        var cleaned = text.replacingOccurrences(of: " ", with: "")
        if cleaned.contains(",") {
            // German input: "." groups thousands, "," is the decimal mark.
            cleaned = cleaned
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: ".")
        }
        return cleaned.isEmpty ? nil : Double(cleaned)
    }
}

enum CarImageSlot {
    case side, front, nav
}

/// Import and pixel-art pipeline for one car image.
@MainActor
@Observable
final class CarImageModel {
    let slot: CarImageSlot
    var imageData: Data?
    var changed = false
    var hasSource = false
    var convertToPixel = false
    var removeBackground = true
    var columns: Double
    var processing = false
    var importError: String?

    @ObservationIgnored private var source: CGImage?
    @ObservationIgnored private var cutout: CGImage?

    init(slot: CarImageSlot, data: Data?) {
        self.slot = slot
        self.imageData = data
        self.columns = slot == .side ? 56 : (slot == .front ? 40 : 32)
    }

    var preview: UIImage {
        if let imageData, let image = UIImage(data: imageData) { return image }
        return slot == .side ? DefaultPixelCar.image : DefaultPixelCar.frontImage
    }

    func load(_ data: Data) async {
        guard let image = UIImage(data: data), let cgImage = PixelArt.normalized(image) else {
            importError = "Unbekanntes Bildformat."
            return
        }
        importError = nil
        source = cgImage
        cutout = nil
        hasSource = true
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let alpha: CGImageAlphaInfo = image.cgImage?.alphaInfo ?? CGImageAlphaInfo.none
        let hasAlpha = !(alpha == CGImageAlphaInfo.none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        // A transparent PNG is probably finished pixel art; a photo gets converted.
        convertToPixel = !(isPNG && hasAlpha)
        await process()
    }

    func process() async {
        guard let source else { return }
        processing = true
        defer { processing = false }

        guard convertToPixel else {
            let limited = PixelArt.limitSize(source)
            imageData = PixelArt.png(PixelArt.trimTransparent(limited) ?? limited)
            changed = true
            return
        }

        var base = source
        if removeBackground {
            if cutout == nil {
                let input = source
                cutout = await Task.detached(priority: .userInitiated) {
                    PixelArt.removeBackground(input).flatMap { PixelArt.trimTransparent($0) }
                }.value
                if cutout == nil {
                    importError = "Kein Motiv erkannt – Hintergrund bleibt."
                }
            }
            base = cutout ?? source
        }
        let cols = Int(columns)
        let input = base
        let result = await Task.detached(priority: .userInitiated) {
            PixelArt.pixelate(input, columns: cols)
        }.value
        if let result {
            imageData = PixelArt.png(PixelArt.trimTransparent(result) ?? result)
            changed = true
        }
    }

    func useDefault() {
        imageData = nil
        changed = true
        source = nil
        cutout = nil
        hasSource = false
        importError = nil
    }
}

/// One image slot in the car editor: preview, import buttons and pixel options.
struct CarImageSection: View {
    let title: String
    let footer: String
    @Bindable var model: CarImageModel
    var onPickFile: () -> Void

    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        Section {
            ZStack {
                background
                PixelImage(image: model.preview)
                    .padding(.horizontal, model.slot == .side ? 36 : (model.slot == .front ? 80 : 120))
                    .padding(.top, 18)
                    .padding(.bottom, model.slot == .side ? 24 : 18)
                if model.processing {
                    ProgressView()
                        .padding(14)
                        .glassEffect(.regular, in: .circle)
                }
            }
            .frame(height: 160)
            .listRowInsets(EdgeInsets())

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Bild aus Fotos wählen", systemImage: "photo.on.rectangle")
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await model.load(data)
                    } else {
                        model.importError = "Das Bild konnte nicht geladen werden."
                    }
                    photoItem = nil
                }
            }
            Button(action: onPickFile) {
                Label("PNG aus Dateien wählen", systemImage: "folder")
            }

            if model.hasSource {
                Toggle("Foto in Pixel-Art umwandeln", isOn: Binding(
                    get: { model.convertToPixel },
                    set: { newValue in
                        model.convertToPixel = newValue
                        Task { await model.process() }
                    }
                ))
                if model.convertToPixel {
                    Toggle("Hintergrund entfernen", isOn: Binding(
                        get: { model.removeBackground },
                        set: { newValue in
                            model.removeBackground = newValue
                            Task { await model.process() }
                        }
                    ))
                    VStack(alignment: .leading) {
                        Text("Pixelbreite: \(Int(model.columns))")
                            .font(.subheadline)
                        Slider(value: $model.columns, in: 16...112, step: 4, onEditingChanged: { editing in
                            if !editing { Task { await model.process() } }
                        })
                    }
                }
            }

            if model.imageData != nil {
                Button("Standard-Bild verwenden", role: .destructive) {
                    model.useDefault()
                }
            }

            if let error = model.importError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    @ViewBuilder
    private var background: some View {
        if model.slot == .side {
            LinearGradient(
                colors: [Color(red: 0.35, green: 0.62, blue: 0.98), Color(red: 0.72, green: 0.87, blue: 1.0)],
                startPoint: .top,
                endPoint: .bottom
            )
            Rectangle()
                .fill(Color(red: 0.22, green: 0.23, blue: 0.27))
                .frame(height: 34)
                .frame(maxHeight: .infinity, alignment: .bottom)
        } else {
            LinearGradient(
                colors: [Color(red: 0.14, green: 0.09, blue: 0.29), Color(red: 0.88, green: 0.34, blue: 0.42)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

struct CarEditorView: View {
    let car: Car
    var isNew = false
    var canDelete = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var draft: CarDraft
    @State private var sideModel: CarImageModel
    @State private var frontModel: CarImageModel
    @State private var navModel: CarImageModel
    @State private var fileTarget: CarImageSlot = .side
    @State private var showFileImporter = false
    @State private var showDelete = false

    init(car: Car, isNew: Bool = false, canDelete: Bool = false) {
        self.car = car
        self.isNew = isNew
        self.canDelete = canDelete
        _draft = State(initialValue: CarDraft(car: car))
        _sideModel = State(initialValue: CarImageModel(slot: .side, data: car.sideImageData))
        _frontModel = State(initialValue: CarImageModel(slot: .front, data: car.frontImageData))
        _navModel = State(initialValue: CarImageModel(slot: .nav, data: car.navImageData))
    }

    private var processing: Bool { sideModel.processing || frontModel.processing || navModel.processing }

    var body: some View {
        NavigationStack {
            Form {
                CarImageSection(
                    title: "Seitenansicht – fürs Fahren",
                    footer: "Seitlich, Front nach rechts. So fährt dein Auto in der Garage durchs Bild.",
                    model: sideModel
                ) {
                    fileTarget = .side
                    showFileImporter = true
                }
                CarImageSection(
                    title: "Schräg von vorne – für Widget & Symbole",
                    footer: "Erscheint im Sperrbildschirm-Widget, in der Auto-Auswahl und neben Fahrten und Sessions. Ein normales Foto wandelt Apex auf Wunsch in Pixel-Art um.",
                    model: frontModel
                ) {
                    fileTarget = .front
                    showFileImporter = true
                }
                CarImageSection(
                    title: "Navigation – Markierung auf der Karte",
                    footer: "Am besten von oben oder von hinten. Ohne eigenes Bild nutzt das Navi das Schräg-vorne-Bild.",
                    model: navModel
                ) {
                    fileTarget = .nav
                    showFileImporter = true
                }
                Section("Fahrzeug") {
                    TextField("Spitzname (z. B. „Blitz“)", text: $draft.nickname)
                    TextField("Marke", text: $draft.make)
                    TextField("Modell", text: $draft.modelName)
                    NumberField(title: "Baujahr", text: $draft.year, unit: "")
                    TextField("Kennzeichen", text: $draft.plate)
                        .textInputAutocapitalization(.characters)
                }
                Section("Leistung") {
                    NumberField(title: "Leistung", text: $draft.power, unit: "PS")
                    NumberField(title: "Drehmoment", text: $draft.torque, unit: "Nm")
                    NumberField(title: "Gewicht", text: $draft.weight, unit: "kg")
                    NumberField(title: "Hubraum", text: $draft.displacement, unit: "cm³")
                    NumberField(title: "0–100 km/h", text: $draft.zeroToHundred, unit: "s", decimal: true)
                    NumberField(title: "Höchstgeschw.", text: $draft.topSpeed, unit: "km/h")
                    Picker("Antrieb", selection: $draft.drivetrain) {
                        ForEach(Drivetrain.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Getriebe", selection: $draft.transmission) {
                        ForEach(Transmission.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    Picker("Kraftstoff", selection: $draft.fuelType) {
                        ForEach(FuelType.allCases) { Text($0.title).tag($0) }
                    }
                    NumberField(title: "Verbrauch", text: $draft.consumption, unit: "l/100 km", decimal: true)
                    NumberField(title: "Tankgröße", text: $draft.tankSize, unit: "l", decimal: true)
                    NumberField(title: "Kilometerstand heute", text: $draft.odometer, unit: "km")
                } header: {
                    Text("Verbrauch & Tank")
                } footer: {
                    Text("Der Kraftstoff bestimmt die Preise in der Garage und im Sperrbildschirm-Widget. Getrackte Kilometer werden zum Kilometerstand addiert.")
                }
                if canDelete && !isNew {
                    Section {
                        Button("Auto löschen", role: .destructive) { showDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "Neues Auto" : "Auto bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                        .disabled(processing)
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.png, .image]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let target = fileTarget == .side ? sideModel : (fileTarget == .front ? frontModel : navModel)
                if let data = try? Data(contentsOf: url) {
                    Task { await target.load(data) }
                } else {
                    target.importError = "Die Datei konnte nicht gelesen werden."
                }
            }
            .confirmationDialog("Auto löschen?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) { deleteCar() }
            } message: {
                Text("Fahrten und Sessions bleiben erhalten, sind dann aber keinem Auto mehr zugeordnet.")
            }
        }
        .interactiveDismissDisabled(isNew)
    }

    // MARK: Actions

    private func save() {
        draft.apply(to: car)
        if sideModel.changed {
            car.sideImageData = sideModel.imageData
        }
        if frontModel.changed {
            car.frontImageData = frontModel.imageData
        }
        if navModel.changed {
            car.navImageData = navModel.imageData
        }
        try? context.save()
        if isNew {
            Persistence.setActive(car)
        } else if car.isActive {
            Persistence.syncActiveCarToWidget()
        }
        dismiss()
    }

    private func cancel() {
        if isNew {
            context.delete(car)
            try? context.save()
        }
        dismiss()
    }

    private func deleteCar() {
        let wasActive = car.isActive
        let target = car
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            context.delete(target)
            try? context.save()
            if wasActive, let next = try? context.fetch(FetchDescriptor<Car>(sortBy: [SortDescriptor(\.createdAt)])).first {
                Persistence.setActive(next)
            }
        }
    }
}

struct NumberField: View {
    let title: String
    @Binding var text: String
    let unit: String
    var decimal = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("–", text: $text)
                    .keyboardType(decimal ? .decimalPad : .numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
