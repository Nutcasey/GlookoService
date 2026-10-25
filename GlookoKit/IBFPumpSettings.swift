import Foundation

/// Therapy values supplied by Loop. No clinical defaults are inferred by the reporting device.
public struct IBFPumpSettings: Codable, Equatable, Sendable {
    public var basal: [Double]
    public var carbRatio: [Double]
    public var sensitivityMGDL: [Double]
    public var targetMGDL: [Double]
    public var correctionThresholdMGDL: [Double]
    public var maximumBolus: Double
    public var maximumBasal: Double
    public var insulinActionMinutes: Int
    public var minimumGlucoseMGDL: Double
    public var glucoseDisplayMMOL: Bool

    public init(basal: [Double], carbRatio: [Double], sensitivityMGDL: [Double], targetMGDL: [Double],
                correctionThresholdMGDL: [Double], maximumBolus: Double, maximumBasal: Double,
                insulinActionMinutes: Int, minimumGlucoseMGDL: Double, glucoseDisplayMMOL: Bool = false) {
        self.basal = basal; self.carbRatio = carbRatio; self.sensitivityMGDL = sensitivityMGDL
        self.targetMGDL = targetMGDL; self.correctionThresholdMGDL = correctionThresholdMGDL
        self.maximumBolus = maximumBolus; self.maximumBasal = maximumBasal
        self.insulinActionMinutes = insulinActionMinutes
        self.minimumGlucoseMGDL = minimumGlucoseMGDL; self.glucoseDisplayMMOL = glucoseDisplayMMOL
    }

    public func validate() throws {
        let profiles = [basal, carbRatio, sensitivityMGDL, targetMGDL, correctionThresholdMGDL]
        guard profiles.allSatisfy({ $0.count == 48 && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 < 65535 } }),
              [carbRatio, sensitivityMGDL, targetMGDL, correctionThresholdMGDL].allSatisfy({ $0.allSatisfy { $0 > 0 } }),
              maximumBolus.isFinite, maximumBolus > 0, maximumBolus < 1000,
              maximumBasal.isFinite, maximumBasal >= (basal.max() ?? 0), maximumBasal < 1000,
              minimumGlucoseMGDL.isFinite, minimumGlucoseMGDL > 0, minimumGlucoseMGDL < 65535,
              insulinActionMinutes > 0, insulinActionMinutes <= 1440 else {
            throw PumpHistoryIBF.EncodingError.invalidSettings
        }
    }
}
