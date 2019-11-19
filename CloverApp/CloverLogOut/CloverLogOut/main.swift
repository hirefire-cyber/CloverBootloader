//
//  main.swift
//  CloverLogOut
//
//  Created by vector sigma on 16/11/2019.
//  Copyright © 2019 CloverHackyColor. All rights reserved.
//

import Foundation

let cmdVersion = "1.0.2"
let savedNVRAMPath = "/tmp/NVRAM_saved"

func log(_ str: String) {
  let logUrl = URL(fileURLWithPath: "/Library/Logs/CloverEFI/clover.daemon.log")
  
  if !fm.fileExists(atPath: "/Library/Logs/CloverEFI") {
    try? fm.createDirectory(at: URL(fileURLWithPath: "/Library/Logs/CloverEFI"),
                            withIntermediateDirectories: false,
                            attributes: nil)
  }
  
  if !fm.fileExists(atPath: "/Library/Logs/CloverEFI/clover.daemon.log") {
    try? "".write(to: logUrl, atomically: false, encoding: .utf8)
  }
  
  if let fh = try? FileHandle(forUpdating: logUrl) {
    fh.seekToEndOfFile()
    fh.write("\n\(str)".data(using: .utf8)!)
    fh.closeFile()
  }
}

func run(cmd: String) {
  let task = Process()
  if #available(OSX 10.13, *) {
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
  } else {
    task.launchPath = "/bin/bash"
  }
  task.environment = ProcessInfo.init().environment
  task.arguments = ["-c", cmd]
  task.launch()
}

func saveNVRAM(nvram: NSMutableDictionary, volume: String) {
  /*
  if (nvram.object(forKey: "efi-backup-boot-device") != nil) {
    nvram.removeObject(forKey: "efi-backup-boot-device")
  }
  
  if (nvram.object(forKey: "efi-backup-boot-device-data") != nil) {
    nvram.removeObject(forKey: "efi-backup-boot-device-data")
  }
  
  if (nvram.object(forKey: "install-product-url") != nil) {
    nvram.removeObject(forKey: "install-product-url")
  }
  
  if (nvram.object(forKey: "previous-system-uuid") != nil) {
    nvram.removeObject(forKey: "previous-system-uuid")
  }
  */
  
  let bsdname = getBSDName(of: volume) ?? ""
  let uuid = getVolumeUUID(from: bsdname) ?? kNotAvailable
  if nvram.write(toFile: volume.addPath("nvram.plist"), atomically: false) {
    log("nvram correctly saved to \(volume) with UUID: \(uuid).")
    nvram.write(toFile: savedNVRAMPath, atomically: false)
    if volume != "/" {
      if fm.fileExists(atPath: "/nvram.plist") {
        do {
          try fm.removeItem(atPath: "/nvram.plist")
        } catch {
          log("\(error)")
        }
      }
    }
  } else {
    log("Error: nvram cannot be saved to \(volume) with UUID: \(uuid).")
  }
}

func disableInsexing(for volume: String) {
  if fm.fileExists(atPath: volume) {
    var file = volume.addPath(".metadata_never_index")
    if !fm.fileExists(atPath: file) {
      try? "".write(toFile: file, atomically: false, encoding: .utf8)
    }
    
    file = volume.addPath(".Spotlight-V100")
    if fm.fileExists(atPath: volume.addPath("")) {
      try? fm.removeItem(atPath: file)
    }
  }
}

func main() {
  let df = DateFormatter()
  df.dateFormat = "yyyy-MM-dd hh:mm:ss"
  df.locale = Locale(identifier: "en_US")
  var now = df.string(from: Date())
  log("- CloverLogOut v\(cmdVersion): logout begin at \(now)")
  if let nvram = getNVRAM() {
    // Check if we're running from CloverEFI
    if (nvram.object(forKey: "EmuVariableUefiPresent") != nil ||
      nvram.object(forKey: "TestEmuVariableUefiPresent") != nil) {
      
      // we already saved once? Check if the nvram is changed
      if fm.fileExists(atPath: savedNVRAMPath) {
        if let old = NSDictionary(contentsOfFile: savedNVRAMPath) {
          if nvram.isEqual(to: old)  {
            log("nvram not changed, nothing to do.")
            log("- CloverLogOut: end at \(now)")
            exit(EXIT_SUCCESS)
          }
        }
      }
      
      
      var disk : String? = nil
      var espList = [String]()
      
      /* find all internal ESP in the System as we don't want
       to save the nvram in a USB pen drive (user will lost the nvram if not plugged in)
       */
      for esp in getAllESPs() {
        if isInternalDevice(diskOrMtp: esp) {
          espList.append(esp)
        }
      }
      
      // find the boot partition device and check if it is a ESP
      if let bd = findBootPartitionDevice() {
        if espList.contains(bd) {
          // boot device is a ESP :-)
          disk = bd
          log("Detected ESP \(bd) as boot device.")
        }
      }
      
      if (disk == nil) {
        // boot device not found
        if espList.count > 0 {
          // we have an internal ESP, using that
          disk = espList[0]
          log("Will use ESP \(disk!) as boot device is not found.")
        } else {
          // use root
          disk = getBSDName(of: "/")
          log("Will use / as no boot device nor an internal ESP are found.")
        }
      }
      
      if (disk != nil) {
        // get the mount point or mount it
        var mounted : Bool = false
        if let mp = getMountPoint(from: disk!) {
          log("\(disk!) was already mounted.")
          saveNVRAM(nvram: nvram, volume: mp)
          if espList.contains(disk!) {
            disableInsexing(for: mp)
          }
          return
        }
        
        if !mounted {
          log("mounting \(disk!)..")
          mount(disk: disk!, at: nil) { (result) in
            if result == true {
              sleep(1)
              var attempts = 0
              repeat {
                attempts+=1
                if let mp = getMountPoint(from: disk!) {
                  mounted = true
                  saveNVRAM(nvram: nvram, volume: mp)
                  if espList.contains(disk!) {
                    disableInsexing(for: mp)
                  }
                  sleep(1)
                  umount(disk: disk!, force: true)
                  break
                }
              } while (mounted || attempts == 5)
            }
          }
        }
        
        if !mounted {
          log("mount failed for \(disk!).")
          saveNVRAM(nvram: nvram, volume: "/")
        }
      } else {
        // CloverDaemonNew should have made the fs read-write for us.
        saveNVRAM(nvram: nvram, volume: "/")
      }
    } else {
      log("EmuVariableUefi is not present, nvram will not be saved.")
    }
  } else {
    log("Error: non nvram to be saved.")
  }
  
  now = df.string(from: Date())
  log("- CloverLogOut: end at \(now)")
}

main()

exit(EXIT_SUCCESS)