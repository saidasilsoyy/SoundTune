// SoundTune/Models/VolumeControlTier.swift
import Foundation

/// The backend used to control volume for a specific output device.
enum VolumeControlTier: String, Codable, Equatable {
    case hardware
    case ddc
    case software
}
