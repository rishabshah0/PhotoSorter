import Foundation
import ImageIO
import CoreGraphics
import SwiftUI
import CoreImage

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }
    
    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}

enum QueueMode: Int, CaseIterable, Identifiable, Sendable {
    case timeline = 0
    case pushDualLast = 1
    case denoisedOnly = 2
    
    var id: Int { self.rawValue }
    
    var displayName: String {
        switch self {
        case .timeline: return "Timeline Sort"
        case .pushDualLast: return "Push Duals to End"
        case .denoisedOnly: return "Denoised Only"
        }
    }
}

struct PhotoItem: Identifiable, Equatable, Hashable {
    let id = UUID()
    let originalURL: URL
    let denoisedURL: URL?
    
    var baseName: String {
        return originalURL.deletingPathExtension().lastPathComponent
    }
    
    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        return lhs.originalURL == rhs.originalURL && lhs.denoisedURL == rhs.denoisedURL
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(originalURL)
        hasher.combine(denoisedURL)
    }
}

actor ImageCache {
    private var cache: [URL: NSImage] = [:]
    
    func get(_ url: URL) -> NSImage? {
        return cache[url]
    }
    
    func set(_ url: URL, image: NSImage) {
        cache[url] = image
    }
    
    func remove(_ url: URL) {
        cache.removeValue(forKey: url)
    }
    
    func clear() {
        cache.removeAll()
    }
    
    func keepOnly(urls: Set<URL>) {
        for url in cache.keys {
            if !urls.contains(url) {
                cache.removeValue(forKey: url)
            }
        }
    }
}

final class PhotoPrefetcher: ObservableObject, @unchecked Sendable {
    @Published var photos: [PhotoItem] = []
    @Published var currentIndex: Int = 0
    @Published var isScanning: Bool = false
    @Published var loadedOriginal: NSImage? = nil
    @Published var loadedDenoised: NSImage? = nil
    @Published var queueMode: QueueMode = QueueMode(rawValue: UserDefaults.standard.integer(forKey: "queueMode")) ?? .timeline {
        didSet {
            UserDefaults.standard.set(queueMode.rawValue, forKey: "queueMode")
            Task { @MainActor in
                self.reSortPhotos()
            }
        }
    }
    
    private let cache = ImageCache()
    private var activePrefetchTasks: [URL: Task<Void, Never>] = [:]
    private var cachedURLs = Set<URL>()
    
    private var urlToIndex: [URL: Int] = [:]  
    private var urlToItem: [URL: PhotoItem] = [:]  
    
    private var currentLoadTask: Task<Void, Never>? = nil
    
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .priorityRequestLow: false
    ])
    
    private let decodeQueue = DispatchQueue(label: "com.rshah.PhotoSorter.decode", qos: .userInitiated, attributes: .concurrent)
    
    private let rawDecodeSemaphore = DispatchSemaphore(value: 4)
    
    private let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "webp", "gif", "bmp", "ico", "jp2",
        "cr3", "cr2", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "orf", "rw2", "pef", "raf", "raw", "kdc", "dcr", "mrw", "mos", "x3f", "erf", "mef", "3fr", "fff"
    ]
    
    private let rawParamsQueue = DispatchQueue(label: "com.rshah.PhotoSorter.rawParams", attributes: .concurrent)
    private var rawParamsCache: [URL: (exposure: Float, boost: Float, boostShadow: Float, width: Double, height: Double)] = [:]
    
    private func cacheParams(for url: URL, exposure: Float, boost: Float, boostShadow: Float, width: Double, height: Double) {
        rawParamsQueue.async(flags: .barrier) {
            self.rawParamsCache[url] = (exposure, boost, boostShadow, width, height)
        }
    }
    
    private func getParams(for url: URL) -> (exposure: Float, boost: Float, boostShadow: Float, width: Double, height: Double)? {
        rawParamsQueue.sync {
            return self.rawParamsCache[url]
        }
    }
    
    func scanDirectory(url: URL) async {
        await MainActor.run {
            self.isScanning = true
            self.photos = []
            self.currentIndex = 0
            self.loadedOriginal = nil
            self.loadedDenoised = nil
            
            for (_, task) in self.activePrefetchTasks {
                task.cancel()
            }
            self.activePrefetchTasks.removeAll()
            self.cachedURLs.removeAll()
        }
        
        await cache.clear()
        
        let fileManager = FileManager.default
        
        let lastPathComponent = url.lastPathComponent
        let baseDir: URL
        if lastPathComponent == "Yes" || lastPathComponent == "No" || lastPathComponent == "Blurry" {
            baseDir = url.deletingLastPathComponent()
        } else {
            baseDir = url
        }
        
        let subfolders = ["", "Yes", "No", "Blurry"]
        var allImageURLs: [URL] = []
        
        for sub in subfolders {
            let scanURL = sub.isEmpty ? baseDir : baseDir.appendingPathComponent(sub)
            guard fileManager.fileExists(atPath: scanURL.path) else { continue }
            do {
                let contents = try fileManager.contentsOfDirectory(at: scanURL, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)
                for fileURL in contents {
                    let ext = fileURL.pathExtension.lowercased()
                    if supportedExtensions.contains(ext) {
                        allImageURLs.append(fileURL)
                    }
                }
            } catch {
                print("Error scanning folder \(scanURL.path): \(error.localizedDescription)")
            }
        }
        
        let denoiseSuffixes = ["-denoise", "-denoised", "_denoise", "_denoised"]
        
        var allOriginals: [String: URL] = [:] 
        var allDenoised: [String: URL] = [:]  
        
        for fileURL in allImageURLs {
            let baseName = fileURL.deletingPathExtension().lastPathComponent
            let baseNameLower = baseName.lowercased()
            
            var isDenoised = false
            for suffix in denoiseSuffixes {
                if baseNameLower.hasSuffix(suffix) {
                    isDenoised = true
                    let mainName = String(baseNameLower.dropLast(suffix.count))
                    allDenoised[mainName] = fileURL
                    break
                }
            }
            
            if !isDenoised {
                allOriginals[baseNameLower] = fileURL
            }
        }
        
        let allKeys = Set(allOriginals.keys).union(allDenoised.keys)
        
        var scannedPhotos: [PhotoItem] = []
        for key in allKeys {
            let orig = allOriginals[key]
            let den = allDenoised[key]
            
            let isOrigInActiveDir = orig != nil && orig!.deletingLastPathComponent().standardized == url.standardized
            let isDenInActiveDir = den != nil && den!.deletingLastPathComponent().standardized == url.standardized
            
            if isOrigInActiveDir || isDenInActiveDir {
                if let origURL = orig, let denURL = den {
                    scannedPhotos.append(PhotoItem(originalURL: origURL, denoisedURL: denURL))
                } else if let origURL = orig {
                    scannedPhotos.append(PhotoItem(originalURL: origURL, denoisedURL: nil))
                } else if let denURL = den {
                    scannedPhotos.append(PhotoItem(originalURL: denURL, denoisedURL: nil))
                }
            }
        }
        
        let unsortedPhotos = scannedPhotos
        await MainActor.run {
            var finalPhotos = unsortedPhotos
            if self.queueMode == .pushDualLast {
                finalPhotos.sort { a, b in
                    let aIsDual = a.denoisedURL != nil
                    let bIsDual = b.denoisedURL != nil
                    if aIsDual != bIsDual {
                        return !aIsDual
                    }
                    return a.baseName.localizedStandardCompare(b.baseName) == .orderedAscending
                }
            } else {
                finalPhotos.sort { $0.baseName.localizedStandardCompare($1.baseName) == .orderedAscending }
            }
            
            self.photos = finalPhotos
            self.isScanning = false
            
            self.urlToIndex.removeAll()
            self.urlToItem.removeAll()
            for (i, item) in finalPhotos.enumerated() {
                self.urlToIndex[item.originalURL] = i
                self.urlToItem[item.originalURL] = item
                if let den = item.denoisedURL {
                    self.urlToIndex[den] = i
                    self.urlToItem[den] = item
                }
            }
            
            if !finalPhotos.isEmpty {
                self.updateCurrentImages()
            }
        }
    }
    
    @MainActor
    func reSortPhotos() {
        guard !photos.isEmpty else { return }
        
        let currentItem = currentIndex < photos.count ? photos[currentIndex] : nil
        
        if queueMode == .pushDualLast {
            photos.sort { a, b in
                let aIsDual = a.denoisedURL != nil
                let bIsDual = b.denoisedURL != nil
                if aIsDual != bIsDual {
                    return !aIsDual
                }
                return a.baseName.localizedStandardCompare(b.baseName) == .orderedAscending
            }
        } else {
            photos.sort { $0.baseName.localizedStandardCompare($1.baseName) == .orderedAscending }
        }
        
        self.urlToIndex.removeAll()
        self.urlToItem.removeAll()
        for (i, item) in photos.enumerated() {
            self.urlToIndex[item.originalURL] = i
            self.urlToItem[item.originalURL] = item
            if let den = item.denoisedURL {
                self.urlToIndex[den] = i
                self.urlToItem[den] = item
            }
        }
        
        if let currentItem = currentItem, let newIndex = urlToIndex[currentItem.originalURL] {
            self.currentIndex = newIndex
        } else {
            self.currentIndex = 0
        }
        
        updateCurrentImages()
    }
    
    func updateCurrentImages() {
        guard currentIndex >= 0 && currentIndex < photos.count else {
            self.loadedOriginal = nil
            self.loadedDenoised = nil
            return
        }
        
        let currentItem = photos[currentIndex]
        let isDenoisedOnlyMode = queueMode == .denoisedOnly
        let hasDenoised = currentItem.denoisedURL != nil && !isDenoisedOnlyMode
        
        currentLoadTask?.cancel()
        
        self.prefetchAhead()
        
        currentLoadTask = Task {
            let primaryURL = (isDenoisedOnlyMode && currentItem.denoisedURL != nil) ? currentItem.denoisedURL! : currentItem.originalURL
            
            let original = await loadOrDecode(url: primaryURL, isDenoised: false, originalURL: nil, forceMatching: hasDenoised)
            if Task.isCancelled { return }
            
            var denoised = hasDenoised ? await loadOrDecode(url: currentItem.denoisedURL!, isDenoised: true, originalURL: currentItem.originalURL, forceMatching: true) : nil
            if Task.isCancelled { return }
            
            if let orig = original, let den = denoised, den.size != orig.size {
                denoised = den.resizedCG(to: orig.size)
            }
            if Task.isCancelled { return }
            
            let finalDenoised = denoised
            await MainActor.run {
                
                if self.currentIndex < self.photos.count && self.photos[self.currentIndex] == currentItem {
                    self.loadedOriginal = original
                    self.loadedDenoised = finalDenoised
                }
            }
        }
    }
    
    func jumpTo(index: Int) {
        guard index >= 0 && index <= photos.count else { return }
        self.currentIndex = index
        self.updateCurrentImages()
    }
    
    func next() {
        if currentIndex < photos.count - 1 {
            currentIndex += 1
            updateCurrentImages()
        } else if currentIndex == photos.count - 1 {
            currentIndex += 1
            self.loadedOriginal = nil
            self.loadedDenoised = nil
        }
    }
    
    private func prefetchAhead() {
        dispatchPrecondition(condition: .onQueue(.main))
        
        let maxBackward = 5
        let maxForward = 15
        
        var urlsToKeep = Set<URL>()
        let isDenoisedOnlyMode = queueMode == .denoisedOnly
        
        var currentItemURLs = Set<URL>()
        if currentIndex < photos.count {
            let cur = photos[currentIndex]
            let primaryURL = (isDenoisedOnlyMode && cur.denoisedURL != nil) ? cur.denoisedURL! : cur.originalURL
            urlsToKeep.insert(primaryURL)
            currentItemURLs.insert(primaryURL)
            if !isDenoisedOnlyMode, let den = cur.denoisedURL {
                urlsToKeep.insert(den)
                currentItemURLs.insert(den)
            }
        }
        
        var targets = [Int]()
        for i in 1...max(maxBackward, maxForward) {
            if i <= maxBackward {
                let prevIdx = currentIndex - i
                if prevIdx >= 0 { targets.append(prevIdx) }
            }
            if i <= maxForward {
                let nextIdx = currentIndex + i
                if nextIdx < photos.count { targets.append(nextIdx) }
            }
        }
        
        for idx in targets {
            let item = photos[idx]
            let primaryURL = (isDenoisedOnlyMode && item.denoisedURL != nil) ? item.denoisedURL! : item.originalURL
            urlsToKeep.insert(primaryURL)
            if !isDenoisedOnlyMode, let den = item.denoisedURL {
                urlsToKeep.insert(den)
            }
        }
        
        Task { [urlsToKeep] in
            await cache.keepOnly(urls: urlsToKeep)
        }
        
        cachedURLs = cachedURLs.intersection(urlsToKeep)
        
        for (url, task) in activePrefetchTasks {
            if !urlsToKeep.contains(url) {
                task.cancel()
                activePrefetchTasks.removeValue(forKey: url)
            }
        }
        
        let getPriority: (URL) -> Int = { [weak self] url in
            guard let self else { return 999999 }
            if let idx = self.urlToIndex[url] {
                let dist = abs(idx - self.currentIndex)
                let isDenoisedOnly = self.queueMode == .denoisedOnly
                let primaryURL = (isDenoisedOnly && self.photos[idx].denoisedURL != nil) ? self.photos[idx].denoisedURL! : self.photos[idx].originalURL
                let isOrig = primaryURL == url
                return dist * 2 + (isOrig ? 0 : 1)
            }
            return 999999
        }
        
        let candidates = urlsToKeep
            .filter { !cachedURLs.contains($0) && !currentItemURLs.contains($0) }
            .sorted { getPriority($0) < getPriority($1) }
        
        let maxConcurrentPrefetches = 6
        if activePrefetchTasks.count > maxConcurrentPrefetches {
            let sortedActive = activePrefetchTasks.keys.sorted { a, b in
                let ia = candidates.firstIndex(of: a) ?? 999999
                let ib = candidates.firstIndex(of: b) ?? 999999
                return ia > ib 
            }
            var toCancel = activePrefetchTasks.count - maxConcurrentPrefetches
            for url in sortedActive {
                guard toCancel > 0 else { break }
                activePrefetchTasks[url]?.cancel()
                activePrefetchTasks.removeValue(forKey: url)
                toCancel -= 1
            }
        }
        
        for url in candidates {
            guard activePrefetchTasks.count < maxConcurrentPrefetches else { break }
            guard activePrefetchTasks[url] == nil else { continue }
            guard let item = urlToItem[url] else { continue }
            
            let isDenoised = (item.denoisedURL == url)
            let originalURL: URL? = isDenoised ? item.originalURL : nil
            let hasDenoised = (item.denoisedURL != nil) && !isDenoisedOnlyMode
            let token = CancellationToken()
            
            let prefetchTask = Task { [url, isDenoised, originalURL, hasDenoised] in
                if await self.cache.get(url) != nil { return }
                if Task.isCancelled { return }
                
                let decoded: NSImage? = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        self.decodeQueue.async {
                            if token.isCancelled { continuation.resume(returning: nil); return }
                            
                            let ext = url.pathExtension.lowercased()
                            let isRAW = ["cr3","cr2","crw","nef","nrw","arw","srf","sr2","dng",
                                         "orf","rw2","pef","raf","raw","kdc","dcr","mrw","mos",
                                         "x3f","erf","mef","3fr","fff"].contains(ext)
                            let needsSemaphore = isRAW && hasDenoised
                            if needsSemaphore {
                                if token.isCancelled { continuation.resume(returning: nil); return }
                                self.rawDecodeSemaphore.wait()
                            }
                            defer { if needsSemaphore { self.rawDecodeSemaphore.signal() } }
                            if token.isCancelled { continuation.resume(returning: nil); return }
                            
                            let img = self.decodeImage(
                                url: url, isDenoised: isDenoised,
                                originalURL: originalURL, forceMatching: hasDenoised,
                                isCancelled: { token.isCancelled }
                            )
                            continuation.resume(returning: img)
                        }
                    }
                } onCancel: { token.cancel() }
                
                if Task.isCancelled { return }
                if let image = decoded { await self.cache.set(url, image: image) }
                
                await MainActor.run { [url, decoded] in
                    if decoded != nil { self.cachedURLs.insert(url) }
                    self.activePrefetchTasks.removeValue(forKey: url)
                    self.prefetchAhead() 
                }
            }
            activePrefetchTasks[url] = prefetchTask
        }
    }
    
    private func loadOrDecode(url: URL, isDenoised: Bool = false, originalURL: URL? = nil, forceMatching: Bool = false) async -> NSImage? {
        
        if let cached = await cache.get(url) { return cached }
        if Task.isCancelled { return nil }
        
        let activeTask = await MainActor.run { self.activePrefetchTasks[url] }
        if let task = activeTask {
            _ = await task.value
            if let cached = await cache.get(url) { return cached }
        }
        if Task.isCancelled { return nil }
        
        let token = CancellationToken()
        let decoded: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.decodeQueue.async {
                    if token.isCancelled { continuation.resume(returning: nil); return }
                    
                    let ext = url.pathExtension.lowercased()
                    let isRAW = ["cr3","cr2","crw","nef","nrw","arw","srf","sr2","dng",
                                 "orf","rw2","pef","raf","raw","kdc","dcr","mrw","mos",
                                 "x3f","erf","mef","3fr","fff"].contains(ext)
                    let needsSemaphore = isRAW && forceMatching
                    if needsSemaphore {
                        if token.isCancelled { continuation.resume(returning: nil); return }
                        self.rawDecodeSemaphore.wait()
                    }
                    defer { if needsSemaphore { self.rawDecodeSemaphore.signal() } }
                    if token.isCancelled { continuation.resume(returning: nil); return }
                    
                    let img = self.decodeImage(url: url, isDenoised: isDenoised,
                                              originalURL: originalURL, forceMatching: forceMatching,
                                              isCancelled: { token.isCancelled })
                    continuation.resume(returning: img)
                }
            }
        } onCancel: { token.cancel() }
        
        if let image = decoded {
            await cache.set(url, image: image)
            _ = await MainActor.run { self.cachedURLs.insert(url) }
        }
        return decoded
    }
    
    private func convertToSRGB(_ image: CGImage) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
    
    private func decodeImage(
        url: URL, 
        isDenoised: Bool = false, 
        originalURL: URL? = nil, 
        forceMatching: Bool = false,
        isCancelled: @escaping () -> Bool = { false }
    ) -> NSImage? {
        if isCancelled() { return nil }
        
        let ext = url.pathExtension.lowercased()
        let isRAW = ["cr3", "cr2", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "orf", "rw2", "pef", "raf", "raw", "kdc", "dcr", "mrw", "mos", "x3f", "erf", "mef", "3fr", "fff"].contains(ext)
        
        if isRAW && forceMatching, let filter = CIRAWFilter(imageURL: url) {
            if isCancelled() { return nil }
            
            guard let rawImage = filter.outputImage else {
                return nil
            }
            let rawW = rawImage.extent.width
            let rawH = rawImage.extent.height
            
            filter.isDraftModeEnabled = true
            filter.isLensCorrectionEnabled = true
            
            var origWidth = rawW
            var origHeight = rawH
            
            if isDenoised, let origURL = originalURL {
                var exposure: Float = 0.0
                var boost: Float = 1.0
                var boostShadow: Float = 0.9
                
                if let cached = self.getParams(for: origURL) {
                    exposure = cached.exposure
                    boost = cached.boost
                    boostShadow = cached.boostShadow
                    origWidth = cached.width
                    origHeight = cached.height
                } else if let origFilter = CIRAWFilter(imageURL: origURL) {
                    exposure = origFilter.baselineExposure
                    boost = origFilter.boostAmount
                    boostShadow = origFilter.boostShadowAmount
                    if let origRaw = origFilter.outputImage {
                        origWidth = origRaw.extent.width
                        origHeight = origRaw.extent.height
                    }
                    self.cacheParams(for: origURL, exposure: exposure, boost: boost, boostShadow: boostShadow, width: origWidth, height: origHeight)
                }
                
                filter.baselineExposure = exposure
                filter.boostAmount = boost
                filter.boostShadowAmount = boostShadow
            } else {
                
                let exposure = filter.baselineExposure
                let boost = filter.boostAmount
                let boostShadow = filter.boostShadowAmount
                self.cacheParams(for: url, exposure: exposure, boost: boost, boostShadow: boostShadow, width: rawW, height: rawH)
            }
            
            let targetMaxDim = 2048.0
            let scale = targetMaxDim / max(origWidth, origHeight)
            filter.scaleFactor = Float(scale)
            
            if isCancelled() { return nil }
            
            guard let scaledImage = filter.outputImage else {
                return nil
            }
            
            var finalImage = scaledImage
            if isDenoised && (rawW != origWidth || rawH != origHeight) {
                let dx = round((rawW - origWidth) / 2.0 * scale)
                let dy = round((rawH - origHeight) / 2.0 * scale)
                let cropW = round(origWidth * scale)
                let cropH = round(origHeight * scale)
                let cropRect = CGRect(x: dx, y: dy, width: cropW, height: cropH)
                finalImage = scaledImage.cropped(to: cropRect)
            }
            
            if isCancelled() { return nil }
            
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            
            guard let cgImage = self.ciContext.createCGImage(finalImage, from: finalImage.extent, format: .RGBA8, colorSpace: colorSpace) else {
                return nil
            }
            
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            return NSImage(cgImage: cgImage, size: size)
        }
        
        if isCancelled() { return nil }
        
        let options: [CFString: Any] = [
            kCGImageSourceShouldAllowFloat: true,
            kCGImageSourceCreateThumbnailFromImageAlways: !isRAW,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ]
        
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        
        if isCancelled() { return nil }
        
        guard var cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        
        if isCancelled() { return nil }
        
        if let srgbImage = convertToSRGB(cgImage) {
            cgImage = srgbImage
        }
        
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }
}

extension NSImage {
    
    func resized(to newSize: NSSize) -> NSImage {
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: newSize),
                  from: NSRect(origin: .zero, size: self.size),
                  operation: .copy,
                  fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    func resizedCG(to newSize: NSSize) -> NSImage {
        
        guard let cgSelf = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return self
        }
        let w = Int(newSize.width)
        let h = Int(newSize.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return self
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgSelf, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let resizedCGImage = ctx.makeImage() else { return self }
        return NSImage(cgImage: resizedCGImage, size: newSize)
    }
}
