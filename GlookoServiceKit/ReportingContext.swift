import Foundation
import HealthKit
import CryptoKit
import LoopKit
import LoopAlgorithm

struct ReportingContext: Codable, Equatable {
    var date: Date
    var sourceID: String?
    var sourceName: String
    var timeZoneIdentifier: String
    var controllerTimeZoneIdentifier: String?
    var settings: IBFPumpSettings?
    var problem: String?
    var insulinName: String?

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }
    var controllerTimeZone: TimeZone { controllerTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? timeZone }
    var isRealPump: Bool { sourceID != nil }

    init(_ stored: StoredSettings) {
        date = stored.date
        controllerTimeZoneIdentifier = stored.controllerTimeZone.identifier
        insulinName = stored.insulinType?.brandName
        timeZoneIdentifier = stored.basalRateSchedule?.timeZone.identifier ?? stored.controllerTimeZone.identifier
        let device = stored.pumpDevice
        sourceName = device?.model ?? device?.name ?? "No pump connected"
        let description = [device?.name, device?.manufacturer, device?.model].compactMap { $0 }.joined(separator: " ").lowercased()
        let serial = device?.udiDeviceIdentifier ?? device?.localIdentifier
        if let device, let serial, !serial.isEmpty, device.manufacturer != nil, device.model != nil,
           !description.contains("mock"), !description.contains("simulator") {
            let identity = [device.name ?? "", device.manufacturer ?? "", device.model ?? "", serial].joined(separator: "|")
            sourceID = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        } else { sourceID = nil }
        // Loop's own model choice (PresetInsulinModelProvider): the pump's insulin type, then the default rapid-acting
        // model, then rapid-acting adult. Onboarded Loop settings usually leave the default model unset.
        let action: TimeInterval
        switch stored.insulinType {
        case .fiasp: action = ExponentialInsulinModelPreset.fiasp.actionDuration
        case .lyumjev: action = ExponentialInsulinModelPreset.lyumjev.actionDuration
        case .afrezza: action = ExponentialInsulinModelPreset.afrezza.actionDuration
        default: action = stored.defaultRapidActingModel?.actionDuration ?? ExponentialInsulinModelPreset.rapidActingAdult.actionDuration
        }
        guard let basal = stored.basalRateSchedule, let ratio = stored.carbRatioSchedule,
              let sensitivity = stored.insulinSensitivitySchedule, let target = stored.glucoseTargetRangeSchedule,
              let maximumBolus = stored.maximumBolus, let maximumBasal = stored.maximumBasalRatePerHour,
              let threshold = stored.suspendThreshold else {
            let missing = [("basal rates", stored.basalRateSchedule == nil), ("carb ratios", stored.carbRatioSchedule == nil),
                           ("insulin sensitivities", stored.insulinSensitivitySchedule == nil),
                           ("glucose targets", stored.glucoseTargetRangeSchedule == nil), ("maximum bolus", stored.maximumBolus == nil),
                           ("maximum basal rate", stored.maximumBasalRatePerHour == nil),
                           ("glucose safety limit", stored.suspendThreshold == nil)].filter(\.1).map(\.0)
            problem = "Waiting for complete Loop therapy settings (missing \(missing.joined(separator: ", "))); no defaults will be uploaded"
            return
        }
        func values<T>(_ items: [RepeatingScheduleValue<T>], _ convert: (T) -> Double) -> [Double] {
            (0..<48).map { slot in
                let item = items.last(where: { $0.startTime <= Double(slot * 1800) }) ?? items[0]
                return convert(item.value)
            }
        }
        guard !basal.items.isEmpty, !ratio.items.isEmpty, !sensitivity.items.isEmpty, !target.items.isEmpty else {
            problem = "Loop has an empty therapy schedule"
            return
        }
        guard action.isFinite, action > 0, action <= 86400 else {
            problem = "Loop has an invalid insulin action duration"
            return
        }
        let mgdl = LoopUnit.milligramsPerDeciliter
        let therapy = IBFPumpSettings(
            basal: values(basal.items, { $0 }), carbRatio: values(ratio.items, { $0 }),
            sensitivityMGDL: values(sensitivity.items, { LoopQuantity(unit: sensitivity.unit, doubleValue: $0).doubleValue(for: mgdl) }),
            targetMGDL: values(target.items, { LoopQuantity(unit: target.unit, doubleValue: $0.minValue).doubleValue(for: mgdl) }),
            correctionThresholdMGDL: values(target.items, { LoopQuantity(unit: target.unit, doubleValue: $0.maxValue).doubleValue(for: mgdl) }),
            maximumBolus: maximumBolus, maximumBasal: maximumBasal, insulinActionMinutes: Int((action / 60).rounded()),
            minimumGlucoseMGDL: threshold.quantity.doubleValue(for: mgdl),
            glucoseDisplayMMOL: stored.bloodGlucoseUnit?.unitString.lowercased().contains("mol") == true)
        do { try therapy.validate(); settings = therapy }
        catch { problem = "Loop therapy settings cannot be represented in this pump format" }
    }

    func hasSameConfiguration(as other: ReportingContext) -> Bool {
        sourceID == other.sourceID && sourceName == other.sourceName && settings == other.settings &&
        timeZoneIdentifier == other.timeZoneIdentifier && controllerTimeZoneIdentifier == other.controllerTimeZoneIdentifier &&
        problem == other.problem && insulinName == other.insulinName
    }
}

extension DoseEntry {
    /// Keep measured volume independently of programmed rate, including final temp basal pulse rounding.
    var sourceDose: SourceDose? {
        guard !manuallyEntered else { return nil }
        let id = syncIdentifier ?? "\(type.rawValue)-\(startDate.timeIntervalSince1970)"
        switch type {
        case .basal, .tempBasal:
            return SourceDose(id: id, kind: type == .basal ? .basal : .tempBasal, start: startDate, end: endDate,
                              rate: unitsPerHour, delivered: isMutable ? nil : unitsInDeliverableIncrements,
                              automatic: automatic, isMutable: isMutable, insulinName: insulinType?.brandName)
        case .suspend:
            return SourceDose(id: id, kind: .suspend, start: startDate, end: endDate, isMutable: isMutable)
        case .resume: return nil
        case .bolus:
            return SourceDose(id: id, kind: .bolus, start: startDate, end: endDate, programmed: programmedUnits,
                              delivered: deliveredUnits, automatic: automatic, isMutable: isMutable, insulinName: insulinType?.brandName)
        }
    }
}
