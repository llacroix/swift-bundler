import Foundation

/// An error returned by ``ResourceBundler``.
enum ResourceBundlerError: LocalizedError {
  case failedToEnumerateBundles(Error)
  case failedToCopyBundle(Error)
  case failedToCreateBundleDirectory(Error)
  case failedToCreateInfoPlist(PlistCreatorError)
  case failedToCopyResource(String, bundle: String)
  case failedToEnumerateBundleContents(Error)
  case failedToCompileMetalShaders(MetalCompilerError)
}

/// A utility for handling resource bundles.
enum ResourceBundler {
  /// Copies the resource bundles present in a source directory into a destination directory. If the bundles
  /// were built by SwiftPM, they will get fixed up to be consistent with bundles built by Xcode.
  /// - Parameters:
  ///   - sourceDirectory: The directory containing generated bundles.
  ///   - destinationDirectory: The directory to copy the bundles to, fixing them if required.
  ///   - fixBundles: If `false`, bundles will be left alone when copying them.
  ///   - minMacOSVersion: The minimum macOS version that the app should run on. Used to create the `Info.plist` for each bundle when `isXcodeBuild` is `false`.
  /// - Returns: If an error occurs, a failure is returned.
  static func copyResourceBundles(
    from sourceDirectory: URL,
    to destinationDirectory: URL,
    fixBundles: Bool,
    minMacOSVersion: String
  ) -> Result<Void, ResourceBundlerError> {
    let contents: [URL]
    do {
      contents = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil, options: [])
    } catch {
      return .failure(.failedToEnumerateBundles(error))
    }
    
    for file in contents where file.pathExtension == "bundle" {
      guard FileManager.default.itemExists(at: file, withType: .directory) else {
        continue
      }
      
      let result: Result<Void, ResourceBundlerError>
      if !fixBundles {
        result = copyResourceBundle(
          file,
          to: destinationDirectory)
      } else {
        result = fixAndCopyResourceBundle(
          file,
          to: destinationDirectory,
          minMacOSVersion: minMacOSVersion)
      }
      
      if case .failure(_) = result {
        return result
      }
    }
    
    return .success()
  }
  
  /// Copies the specified resource bundle into a destination directory.
  /// - Parameters:
  ///   - bundle: The bundle to copy.
  ///   - destination: The directory to copy the bundle to.
  /// - Returns: If an error occurs, a failure is returned.
  static func copyResourceBundle(_ bundle: URL, to destination: URL) -> Result<Void, ResourceBundlerError> {
    log.info("Copying resource bundle '\(bundle.lastPathComponent)'")
    
    let destinationBundle = destination.appendingPathComponent(bundle.lastPathComponent)
    
    do {
      try FileManager.default.copyItem(at: bundle, to: destinationBundle)
    } catch {
      return .failure(.failedToCopyBundle(error))
    }
    
    return .success()
  }
  
  /// Copies the specified resource bundle into a destination directory. Before copying, the bundle
  /// is fixed up to be consistent with bundles built by Xcode.
  ///
  /// Creates the proper bundle structure, adds an `Info.plist` and compiles any metal shaders present in the bundle.
  /// - Parameters:
  ///   - bundle: The bundle to fix and copy.
  ///   - destination: The directory to copy the bundle to.
  ///   - minMacOSVersion: The minimum macOS version that the app should run on. Used to created the bundle's `Info.plist`.
  /// - Returns: If an error occurs, a failure is returned.
  static func fixAndCopyResourceBundle(
    _ bundle: URL,
    to destination: URL,
    minMacOSVersion: String
  ) -> Result<Void, ResourceBundlerError> {
    log.info("Fixing and copying resource bundle '\(bundle.lastPathComponent)'")
    
    let destinationBundle = destination.appendingPathComponent(bundle.lastPathComponent)
    let destinationBundleResources = destinationBundle
      .appendingPathComponent("Contents")
      .appendingPathComponent("Resources")
    
    // The bundle was generated by SwiftPM, so it's gonna need a bit of fixing
    let copyBundle = flatten(
      { createResourceBundleDirectoryStructure(at: destinationBundle) },
      { createResourceBundleInfoPlist(in: destinationBundle, minMacOSVersion: minMacOSVersion) },
      { copyResources(from: bundle, to: destinationBundleResources) },
      {
        MetalCompiler.compileMetalShaders(in: destinationBundleResources, keepSources: false)
          .mapError { error in
            .failedToCompileMetalShaders(error)
          }
      })
    
    return copyBundle()
  }
  
  // MARK: Private methods
  
  /// Creates the following structure for the specified resource bundle directory:
  ///
  /// - `Contents`
  ///   - `Info.plist`
  ///   - `Resources`
  /// - Parameter bundle: The bundle to create.
  /// - Returns: If an error occurs, a failure is returned.
  private static func createResourceBundleDirectoryStructure(at bundle: URL) -> Result<Void, ResourceBundlerError> {
    let bundleContents = bundle.appendingPathComponent("Contents")
    let bundleResources = bundleContents.appendingPathComponent("Resources")
    
    do {
      try FileManager.default.createDirectory(at: bundleResources)
    } catch {
      return .failure(.failedToCreateBundleDirectory(error))
    }
    
    return .success()
  }
  
  /// Creates the `Info.plist` file for a resource bundle.
  /// - Parameter bundle: The bundle to create the `Info.plist` file for.
  /// - Parameter minMacOSVersion: The minimum macOS version that the resource bundle should work on.
  /// - Returns: If an error occurs, a failure is returned.
  private static func createResourceBundleInfoPlist(in bundle: URL, minMacOSVersion: String) -> Result<Void, ResourceBundlerError> {
    let bundleName = bundle.deletingPathExtension().lastPathComponent
    let infoPlist = bundle
      .appendingPathComponent("Contents")
      .appendingPathComponent("Info.plist")
    
    let result = PlistCreator.createResourceBundleInfoPlist(
      at: infoPlist,
      bundleName: bundleName,
      minMacOSVersion: minMacOSVersion)
    
    if case let .failure(error) = result {
      return .failure(.failedToCreateInfoPlist(error))
    }
    
    return .success()
  }
  
  /// Copies the resources from a source directory to a destination directory.
  ///
  /// If any of the resources are metal shader sources, they get compiled into a `default.metallib`.
  /// After compilation, the sources are deleted.
  /// - Parameters:
  ///   - source: The source directory.
  ///   - destination: The destination directory.
  /// - Returns: If an error occurs, a failure is returned.
  private static func copyResources(from source: URL, to destination: URL) -> Result<Void, ResourceBundlerError> {
    let contents: [URL]
    do {
      contents = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [])
    } catch {
      return .failure(.failedToEnumerateBundleContents(error))
    }
    
    for file in contents {
      do {
        try FileManager.default.copyItem(
          at: file,
          to: destination.appendingPathComponent(file.lastPathComponent))
      } catch {
        return .failure(.failedToCopyResource(file.lastPathComponent, bundle: source.lastPathComponent))
      }
    }
    
    return .success()
  }
}
