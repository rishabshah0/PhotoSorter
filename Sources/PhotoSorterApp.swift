import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ReviewMode: String, CaseIterable, Identifiable {
    case queue = "Queue"
    case yes = "Liked"
    case no = "Disliked"
    case blurry = "Blurry"
    
    var id: String { self.rawValue }
}

enum SwipeDirection {
    case left, right, down
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        
    }
}

@main
struct PhotoSorterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 1050, minHeight: 750)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct MainView: View {
    @StateObject private var prefetcher = PhotoPrefetcher()
    @StateObject private var fileQueue = FileManagerQueue()
    
    @State private var selectedDirectory: URL? = nil
    @State private var rootDirectory: URL? = nil
    @State private var directoryHistory: [URL] = []
    
    @State private var reviewMode: ReviewMode = .queue
    
    @State private var splitFraction: Double = 0.5
    @State private var showSlider = true
    @State private var selectedVersionDenoised = true
    
    @State private var zoomEnabled = false
    
    @State private var imageOffset: CGSize = .zero
    @State private var imageRotation: Double = 0.0
    @State private var imageScale: CGFloat = 1.0
    @State private var imageOpacity: Double = 1.0
    @State private var isAnimating = false
    
    @State private var isScrollingGestureActive = false
    @State private var scrollAccumulatedTranslation: CGSize = .zero
    
    private var dragProgress: Double {
        let maxDist: CGFloat = 150.0
        let w = imageOffset.width
        let h = imageOffset.height
        if abs(w) > abs(h) {
            return Double(min(1.0, abs(w) / maxDist))
        } else {
            return Double(min(1.0, max(0.0, h) / maxDist))
        }
    }
    
    private var tintColor: Color {
        let w = imageOffset.width
        let h = imageOffset.height
        if abs(w) > abs(h) {
            return w > 0 ? Color.green : Color.red
        } else {
            return h > 0 ? Color.yellow : Color.clear
        }
    }
    
    @State private var queueCount: Int = 0
    @State private var likedCount: Int = 0
    @State private var dislikedCount: Int = 0
    @State private var blurryCount: Int = 0
    
    private func updateDirectoryCounts() {
        guard let root = rootDirectory else { return }
        
        let fileManager = FileManager.default
        let supportedExts: Set<String> = [
            "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "webp", "gif", "bmp", "ico", "jp2",
            "cr3", "cr2", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "orf", "rw2", "pef", "raf", "raw", "kdc", "dcr", "mrw", "mos", "x3f", "erf", "mef", "3fr", "fff"
        ]
        let denoiseSuffixes = ["-denoise", "-denoised", "_denoise", "_denoised"]
        
        let countImagesInDir: (URL) -> Int = { dirURL in
            guard fileManager.fileExists(atPath: dirURL.path) else { return 0 }
            do {
                let files = try fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                let imageFiles = files.filter { supportedExts.contains($0.pathExtension.lowercased()) }
                
                var baseNames = Set<String>()
                for file in imageFiles {
                    let base = file.deletingPathExtension().lastPathComponent
                    var baseLower = base.lowercased()
                    for suffix in denoiseSuffixes {
                        if baseLower.hasSuffix(suffix) {
                            baseLower = String(baseLower.dropLast(suffix.count))
                            break
                        }
                    }
                    baseNames.insert(baseLower)
                }
                return baseNames.count
            } catch {
                return 0
            }
        }
        
        let qCount = countImagesInDir(root)
        let lCount = countImagesInDir(root.appendingPathComponent("Yes"))
        let dCount = countImagesInDir(root.appendingPathComponent("No"))
        let bCount = countImagesInDir(root.appendingPathComponent("Blurry"))
        
        DispatchQueue.main.async {
            self.queueCount = qCount
            self.likedCount = lCount
            self.dislikedCount = dCount
            self.blurryCount = bCount
        }
    }
    
    var body: some View {
        ZStack {
            
            Color(red: 0.95, green: 0.95, blue: 0.97)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                
                HStack(spacing: 16) {
                    
                    MiniIconView()
                        .padding(.leading, 24)
                        .offset(y: 4)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PhotoSorter")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                        
                        HStack(spacing: 4) {
                            if !directoryHistory.isEmpty {
                                Button(action: goUpDirectory) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.up.circle.fill")
                                        Text("Parent")
                                    }
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.blue)
                                }
                                .buttonStyle(.plain)
                                
                                Text(">")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            
                            if let dir = selectedDirectory {
                                let folderNameMap = ["Yes": "Liked", "No": "Disliked"]
                                let rawName = dir.lastPathComponent
                                let displayName = folderNameMap[rawName] ?? rawName
                                Text(displayName)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.primary)
                            } else {
                                Text("No folder active")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    if selectedDirectory != nil {
                        Picker("", selection: Binding(
                            get: { self.reviewMode },
                            set: { self.switchReviewMode(to: $0) }
                        )) {
                            ForEach(ReviewMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.regular)
                        .frame(width: 360)
                    }
                    
                    Spacer()
                    
                    if prefetcher.isScanning {
                        ProgressView()
                            .scaleEffect(0.8)
                            .padding(.trailing, 8)
                    }
                    
                    if selectedDirectory != nil {
                        Button(action: selectDirectory) {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                Text("Open Folder")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.clear, in: .rect(cornerRadius: 8))
                        .foregroundColor(.black)
                    }
                }
                .padding(.top, 36) 
                .padding(.trailing, 24)
                .padding(.bottom, 16)
                .background(Color.white.opacity(0.15))
                .border(SeparatorShapeStyle(), width: 1)
                
                if !prefetcher.photos.isEmpty {
                    let totalVal = reviewMode == .queue
                        ? (queueCount + likedCount + dislikedCount + blurryCount)
                        : prefetcher.photos.count
                    
                    let currentVal = reviewMode == .queue
                        ? (likedCount + dislikedCount + blurryCount)
                        : prefetcher.currentIndex
                    
                    ProgressProgressBar(
                        current: currentVal,
                        total: totalVal
                    )
                }
                
                ZStack {
                    if prefetcher.photos.isEmpty {
                        EmptyStateView(selectAction: selectDirectory)
                    } else if prefetcher.currentIndex >= prefetcher.photos.count {
                        FinishedPassView(
                            yesCount: likedCount,
                            drillDownAction: drillDownIntoYes,
                            goUpAction: directoryHistory.isEmpty ? nil : goUpDirectory,
                            isQueueMode: reviewMode == .queue
                        )
                    } else {
                        let currentItem = prefetcher.photos[prefetcher.currentIndex]
                        
                        VStack(spacing: 12) {
                            
                            ZStack(alignment: .bottom) {
                                
                                ZStack {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(Color.white)
                                        .shadow(color: Color.black.opacity(0.03), radius: 15, x: 0, y: 6)
                                    
                                    if let original = prefetcher.loadedOriginal {
                                        if let denoised = prefetcher.loadedDenoised, showSlider {
                                            ComparisonSliderView(
                                                original: original,
                                                denoised: denoised,
                                                splitFraction: $splitFraction,
                                                zoomEnabled: $zoomEnabled
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 16))
                                        } else {
                                            let activeImage = (currentItem.denoisedURL != nil && prefetcher.queueMode != .denoisedOnly && selectedVersionDenoised)
                                                ? (prefetcher.loadedDenoised ?? original)
                                                : original
                                            
                                            SingleImageLoupeView(
                                                image: activeImage,
                                                zoomEnabled: $zoomEnabled
                                            )
                                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                        }
                                    } else {
                                        VStack(spacing: 12) {
                                            ProgressView()
                                            Text("Decoding RAW Image...")
                                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                    
                                    if dragProgress > 0.01 && tintColor != .clear {
                                        tintColor
                                            .opacity(dragProgress * 0.25)
                                            .allowsHitTesting(false)
                                            .clipShape(RoundedRectangle(cornerRadius: 16))
                                    }
                                }
                                .offset(imageOffset)
                                .rotationEffect(.degrees(imageRotation))
                                .scaleEffect(imageScale)
                                .opacity(imageOpacity)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            guard !zoomEnabled, !isAnimating else { return }
                                            imageOffset = value.translation
                                            imageRotation = Double(value.translation.width / 20)
                                        }
                                        .onEnded { value in
                                            guard !zoomEnabled, !isAnimating else { return }
                                            let threshold: CGFloat = 150
                                            let translation = value.translation
                                            
                                            if translation.width > threshold {
                                                handleSwipe(direction: .right)
                                            } else if translation.width < -threshold {
                                                handleSwipe(direction: .left)
                                            } else if translation.height > threshold {
                                                handleSwipe(direction: .down)
                                            } else {
                                                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                                                    imageOffset = .zero
                                                    imageRotation = 0
                                                }
                                            }
                                        }
                                )
                                
                                if prefetcher.loadedOriginal != nil {
                                    HStack(spacing: 12) {
                                        
                                        LiquidNavButton(
                                            key: "⌘Z",
                                            icon: "arrow.uturn.backward",
                                            helpText: "Undo last sort operation"
                                        ) {
                                            undoLastMove()
                                        }
                                        .disabled(fileQueue.undoStack.isEmpty)
                                        
                                        LiquidNavButton(
                                            key: "←",
                                            icon: "chevron.left",
                                            helpText: "Go to previous photo"
                                        ) {
                                            goToPreviousPhoto()
                                        }
                                        .disabled(prefetcher.currentIndex == 0)
                                        
                                        LiquidNavButton(
                                            key: "→",
                                            icon: "chevron.right",
                                            helpText: "Go to next photo"
                                        ) {
                                            goToNextPhoto()
                                        }
                                        .disabled(prefetcher.currentIndex == prefetcher.photos.count - 1)
                                        
                                        Divider()
                                            .frame(height: 24)
                                            .foregroundColor(.secondary.opacity(0.3))
                                        
                                        if reviewMode == .queue {
                                            if currentItem.denoisedURL != nil && prefetcher.queueMode != .denoisedOnly {
                                                
                                                LiquidCircularButton(
                                                    key: "1",
                                                    icon: "xmark",
                                                    badgeColor: Color(red: 0.94, green: 0.27, blue: 0.27),
                                                    helpText: "Discard both versions (move to Disliked)"
                                                ) {
                                                    rateCurrentPhoto(target: "DiscardBoth")
                                                }
                                                
                                                LiquidCircularButton(
                                                    key: "2",
                                                    icon: "eye.slash.fill",
                                                    badgeColor: Color(red: 0.95, green: 0.60, blue: 0.10),
                                                    helpText: "Mark both as Blurry"
                                                ) {
                                                    rateCurrentPhoto(target: "Blurry")
                                                }
                                                
                                                LiquidCircularButton(
                                                    key: "3",
                                                    icon: "checkmark",
                                                    badgeColor: Color(red: 0.13, green: 0.77, blue: 0.37),
                                                    helpText: "Accept denoised, move original to Blurry"
                                                ) {
                                                    rateCurrentPhoto(target: "AcceptRight")
                                                }
                                            } else {
                                                
                                                LiquidCircularButton(
                                                    key: "1",
                                                    icon: "xmark",
                                                    badgeColor: Color(red: 0.94, green: 0.27, blue: 0.27),
                                                    helpText: "Move to Disliked"
                                                ) {
                                                    rateCurrentPhoto(target: "No")
                                                }
                                                
                                                LiquidCircularButton(
                                                    key: "2",
                                                    icon: "eye.slash.fill",
                                                    badgeColor: Color(red: 0.95, green: 0.60, blue: 0.10),
                                                    helpText: "Move to Blurry"
                                                ) {
                                                    rateCurrentPhoto(target: "Blurry")
                                                }
                                                
                                                LiquidCircularButton(
                                                    key: "3",
                                                    icon: "checkmark",
                                                    badgeColor: Color(red: 0.13, green: 0.77, blue: 0.37),
                                                    helpText: "Move to Liked"
                                                ) {
                                                    rateCurrentPhoto(target: "Yes")
                                                }
                                            }
                                        } else if reviewMode == .yes {
                                            
                                            LiquidCircularButton(
                                                key: "1",
                                                icon: "xmark",
                                                badgeColor: Color(red: 0.94, green: 0.27, blue: 0.27),
                                                helpText: "Move to Disliked"
                                            ) {
                                                rateCurrentPhoto(target: "MoveToNo")
                                            }
                                            
                                            LiquidCircularButton(
                                                key: "2",
                                                icon: "eye.slash.fill",
                                                badgeColor: Color(red: 0.95, green: 0.60, blue: 0.10),
                                                helpText: "Move to Blurry"
                                            ) {
                                                rateCurrentPhoto(target: "MoveToBlurry")
                                            }
                                            
                                        } else if reviewMode == .no {
                                            
                                            LiquidCircularButton(
                                                key: "1",
                                                icon: "arrow.uturn.backward",
                                                badgeColor: Color(red: 0.94, green: 0.27, blue: 0.27),
                                                helpText: "Restore to Queue"
                                            ) {
                                                rateCurrentPhoto(target: "Restore")
                                            }
                                            
                                            LiquidCircularButton(
                                                key: "2",
                                                icon: "eye.slash.fill",
                                                badgeColor: Color(red: 0.95, green: 0.60, blue: 0.10),
                                                helpText: "Move to Blurry"
                                            ) {
                                                rateCurrentPhoto(target: "MoveToBlurry")
                                            }
                                        } else if reviewMode == .blurry {
                                            
                                            LiquidCircularButton(
                                                key: "1",
                                                icon: "arrow.uturn.backward",
                                                badgeColor: Color(red: 0.94, green: 0.27, blue: 0.27),
                                                helpText: "Restore to Queue"
                                            ) {
                                                rateCurrentPhoto(target: "Restore")
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .glassEffect(.clear, in: Capsule())
                                    .shadow(color: Color.black.opacity(0.05), radius: 8, y: 4)
                                    .padding(.bottom, 20)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 16)

                            HStack(spacing: 20) {
                                Text(currentItem.originalURL.lastPathComponent)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.white.opacity(0.8))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.black.opacity(0.05), lineWidth: 1)
                                    )
                                
                                if currentItem.denoisedURL != nil {
                                    Divider()
                                        .frame(height: 16)
                                    
                                    Toggle(isOn: $showSlider) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "slider.horizontal.2.square")
                                            Text("Split Compare")
                                        }
                                        .font(.system(size: 11, weight: .semibold))
                                    }
                                    .toggleStyle(.checkbox)
                                    
                                    if !showSlider {
                                        Picker("", selection: $selectedVersionDenoised) {
                                            Text("Original").tag(false)
                                            Text("Denoised").tag(true)
                                        }
                                        .pickerStyle(.segmented)
                                        .frame(width: 140)
                                    }
                                }
                                
                                Divider()
                                    .frame(height: 16)
                                
                                Picker("", selection: $prefetcher.queueMode) {
                                    ForEach(QueueMode.allCases) { mode in
                                        Text(mode.displayName).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 360)
                                
                                Spacer()
                                
                                if reviewMode == .queue && likedCount > 0 {
                                    Button(action: drillDownIntoYes) {
                                        HStack(spacing: 4) {
                                            Text("Drill Down (\(likedCount) Liked)")
                                            Image(systemName: "arrow.right.to.line")
                                        }
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.blue.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 28)
                            .padding(.bottom, 16)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity) 
            }
        }
        .ignoresSafeArea()
        .onAppear {
            setupKeyboardMonitor()
            setupScrollGestureMonitor()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                var targetURL: URL? = nil
                if let url = item as? URL {
                    targetURL = url
                } else if let data = item as? Data {
                    targetURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let string = item as? String {
                    targetURL = URL(string: string)
                }
                
                if let url = targetURL {
                    let resolvedURL = url.standardized
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDir), isDir.boolValue {
                        DispatchQueue.main.async {
                            self.loadRootDirectory(url: resolvedURL)
                        }
                    }
                }
            }
            return true
        }
    }
    
    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.title = "Select Photo Directory"
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                loadRootDirectory(url: url)
            }
        }
    }
    
    private func loadRootDirectory(url: URL) {
        rootDirectory = url
        
        let yesDir = url.appendingPathComponent("Yes")
        let fileManager = FileManager.default
        var hasYesPhotos = false
        
        if fileManager.fileExists(atPath: yesDir.path) {
            do {
                let files = try fileManager.contentsOfDirectory(at: yesDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                let supportedExts: Set<String> = [
                    "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "webp", "gif", "bmp", "ico", "jp2",
                    "cr3", "cr2", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "orf", "rw2", "pef", "raf", "raw", "kdc", "dcr", "mrw", "mos", "x3f", "erf", "mef", "3fr", "fff"
                ]
                let imageFiles = files.filter { supportedExts.contains($0.pathExtension.lowercased()) }
                if !imageFiles.isEmpty {
                    hasYesPhotos = true
                }
            } catch {
                print("Error checking Yes directory: \(error)")
            }
        }
        
        if hasYesPhotos {
            reviewMode = .yes
            selectedDirectory = yesDir
            directoryHistory = [url]
        } else {
            reviewMode = .queue
            selectedDirectory = url
            directoryHistory = []
        }
        
        self.updateDirectoryCounts()
        
        if let targetUrl = selectedDirectory {
            Task {
                await prefetcher.scanDirectory(url: targetUrl)
            }
        }
    }
    
    private func switchReviewMode(to mode: ReviewMode) {
        guard let root = rootDirectory else { return }
        
        reviewMode = mode
        let targetDir: URL
        switch mode {
        case .queue:
            targetDir = root
            directoryHistory = []
        case .yes:
            targetDir = root.appendingPathComponent("Yes")
            directoryHistory = [root]
        case .no:
            targetDir = root.appendingPathComponent("No")
            directoryHistory = [root]
        case .blurry:
            targetDir = root.appendingPathComponent("Blurry")
            directoryHistory = [root]
        }
        
        selectedDirectory = targetDir
        self.updateDirectoryCounts()
        Task {
            await prefetcher.scanDirectory(url: targetDir)
        }
    }
    
    private func drillDownIntoYes() {
        guard rootDirectory != nil else { return }
        switchReviewMode(to: .yes)
    }
    
    private func goUpDirectory() {
        guard rootDirectory != nil else { return }
        switchReviewMode(to: .queue)
    }
    
    private func rateCurrentPhoto(target: String) {
        guard !isAnimating, prefetcher.currentIndex < prefetcher.photos.count else { return }
        
        isAnimating = true
        let currentItem = prefetcher.photos[prefetcher.currentIndex]
        let originalIndex = prefetcher.currentIndex
        
        withAnimation(.easeOut(duration: 0.22)) {
            if target == "DiscardBoth" || target == "No" || target == "MoveToNo" || target == "Restore" {
                imageOffset = CGSize(width: -1000, height: 0)
                imageRotation = -12
                imageOpacity = 0
            } else if target == "AcceptLeft" || target == "AcceptRight" || target == "Yes" || target == "Keep" || target == "MoveToYes" {
                imageOffset = CGSize(width: 1000, height: 0)
                imageRotation = 12
                imageOpacity = 0
            } else if target == "Blurry" || target == "MoveToBlurry" {
                imageOffset = CGSize(width: 0, height: 1000)
                imageRotation = 0
                imageOpacity = 0
            }
        }
        
        fileQueue.sortPhoto(
            item: currentItem,
            atIndex: originalIndex,
            action: target,
            baseDir: rootDirectory ?? selectedDirectory!
        ) { record in
            guard record != nil else {
                withAnimation {
                    self.imageOffset = .zero
                    self.imageRotation = 0
                    self.imageScale = 1.0
                    self.imageOpacity = 1.0
                    self.isAnimating = false
                }
                return
            }
            
            self.updateDirectoryCounts()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                self.prefetcher.next()
                
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self.imageOffset = .zero
                    self.imageRotation = 0
                    self.imageScale = 0.96
                    self.imageOpacity = 0.0
                }
                
                withAnimation(.easeOut(duration: 0.18)) {
                    self.imageScale = 1.0
                    self.imageOpacity = 1.0
                }
                
                self.isAnimating = false
            }
        }
    }
    
    private func handleSwipe(direction: SwipeDirection) {
        guard prefetcher.currentIndex < prefetcher.photos.count else { return }
        let currentItem = prefetcher.photos[prefetcher.currentIndex]
        
        let target: String
        switch reviewMode {
        case .queue:
            if direction == .right {
                target = (currentItem.denoisedURL != nil && prefetcher.queueMode != .denoisedOnly) ? "AcceptRight" : "Yes"
            } else if direction == .left {
                target = (currentItem.denoisedURL != nil && prefetcher.queueMode != .denoisedOnly) ? "DiscardBoth" : "No"
            } else { 
                target = "Blurry"
            }
        case .yes:
            if direction == .right {
                target = "Keep"
            } else if direction == .left {
                target = "MoveToNo"
            } else { 
                target = "MoveToBlurry"
            }
        case .no:
            if direction == .right {
                target = "Keep"
            } else if direction == .left {
                target = "Restore"
            } else { 
                target = "MoveToBlurry"
            }
        case .blurry:
            if direction == .right {
                target = "Keep"
            } else if direction == .left {
                target = "Restore"
            } else { 
                target = "Keep"
            }
        }
        
        rateCurrentPhoto(target: target)
    }
    
    private func goToPreviousPhoto() {
        guard prefetcher.currentIndex > 0 else { return }
        prefetcher.currentIndex -= 1
        prefetcher.updateCurrentImages()
    }
    
    private func goToNextPhoto() {
        guard prefetcher.currentIndex < prefetcher.photos.count - 1 else { return }
        prefetcher.currentIndex += 1
        prefetcher.updateCurrentImages()
    }
    
    private func undoLastMove() {
        guard !isAnimating else { return }
        isAnimating = true
        
        fileQueue.undoLastMove { record in
            guard let record = record else {
                self.isAnimating = false
                return
            }
            
            self.updateDirectoryCounts()
            
            self.prefetcher.jumpTo(index: record.index)
            self.selectedVersionDenoised = record.selectedVersionDenoised
            
            let entryOffset: CGSize
            let entryRotation: Double
            
            if record.targetFolder == "DiscardBoth" || record.targetFolder == "No" {
                entryOffset = CGSize(width: -1000, height: 0)
                entryRotation = -12
            } else if record.targetFolder == "AcceptLeft" || record.targetFolder == "AcceptRight" || record.targetFolder == "Yes" {
                entryOffset = CGSize(width: 1000, height: 0)
                entryRotation = 12
            } else {
                entryOffset = CGSize(width: 0, height: 500)
                entryRotation = 0
            }
            
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.imageOffset = entryOffset
                self.imageRotation = entryRotation
                self.imageScale = 0.95
                self.imageOpacity = 0.0
            }
            
            withAnimation(.easeOut(duration: 0.25)) {
                self.imageOffset = .zero
                self.imageRotation = 0
                self.imageScale = 1.0
                self.imageOpacity = 1.0
            }
            
            self.isAnimating = false
        }
    }
    
    private func setupKeyboardMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.selectedDirectory != nil, !self.prefetcher.photos.isEmpty else {
                return event
            }
            
            if self.isAnimating {
                return event
            }
            
            if event.keyCode == 123 { 
                self.goToPreviousPhoto()
                return nil
            } else if event.keyCode == 124 { 
                self.goToNextPhoto()
                return nil
            }
            
            let isCmdPressed = event.modifierFlags.contains(.command)
            
            if let chars = event.characters {
                if isCmdPressed && chars.lowercased() == "z" {
                    self.undoLastMove()
                    return nil
                }
                
                let currentItem = self.prefetcher.photos[self.prefetcher.currentIndex]
                
                if self.reviewMode == .queue {
                    let isSplitCompareActive = currentItem.denoisedURL != nil && self.prefetcher.queueMode != .denoisedOnly
                    if isSplitCompareActive {
                        if chars == "1" || chars.lowercased() == "x" || chars.lowercased() == "d" {
                            self.rateCurrentPhoto(target: "DiscardBoth")
                            return nil
                        } else if chars == "2" {
                            self.rateCurrentPhoto(target: "Blurry")
                            return nil
                        } else if chars == "3" {
                            self.rateCurrentPhoto(target: "AcceptRight")
                            return nil
                        }
                    } else {
                        if chars == "1" || chars.lowercased() == "x" || chars.lowercased() == "d" {
                            self.rateCurrentPhoto(target: "No")
                            return nil
                        } else if chars == "2" {
                            self.rateCurrentPhoto(target: "Blurry")
                            return nil
                        } else if chars == "3" {
                            self.rateCurrentPhoto(target: "Yes")
                            return nil
                        }
                    }
                } else if self.reviewMode == .yes {
                    if chars == "1" || chars.lowercased() == "x" || chars.lowercased() == "d" {
                        self.rateCurrentPhoto(target: "MoveToNo")
                        return nil
                    } else if chars == "2" {
                        self.rateCurrentPhoto(target: "MoveToBlurry")
                        return nil
                    }
                } else if self.reviewMode == .no {
                    if chars == "1" || chars.lowercased() == "x" || chars.lowercased() == "d" {
                        self.rateCurrentPhoto(target: "Restore")
                        return nil
                    } else if chars == "2" {
                        self.rateCurrentPhoto(target: "MoveToBlurry")
                        return nil
                    }
                } else if self.reviewMode == .blurry {
                    if chars == "1" || chars.lowercased() == "x" || chars.lowercased() == "d" {
                        self.rateCurrentPhoto(target: "Restore")
                        return nil
                    }
                }
            }
            
            if event.keyCode == 51 { 
                self.undoLastMove()
                return nil
            }
            
            return event
        }
    }
    
    private func setupScrollGestureMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard self.selectedDirectory != nil, !self.prefetcher.photos.isEmpty, !self.zoomEnabled, !self.isAnimating else {
                return event
            }
            
            let phase = event.phase
            
            if phase == .began {
                self.isScrollingGestureActive = true
                self.scrollAccumulatedTranslation = .zero
            } else if phase == .changed && self.isScrollingGestureActive {
                let dx = -event.scrollingDeltaX
                let dy = -event.scrollingDeltaY
                
                self.scrollAccumulatedTranslation.width += dx
                self.scrollAccumulatedTranslation.height += dy
                
                self.imageOffset = self.scrollAccumulatedTranslation
                self.imageRotation = Double(self.scrollAccumulatedTranslation.width / 20)
            } else if (phase == .ended || phase == .cancelled) && self.isScrollingGestureActive {
                self.isScrollingGestureActive = false
                let threshold: CGFloat = 150
                let translation = self.scrollAccumulatedTranslation
                
                if translation.width > threshold {
                    self.handleSwipe(direction: .right)
                } else if translation.width < -threshold {
                    self.handleSwipe(direction: .left)
                } else if translation.height > threshold {
                    self.handleSwipe(direction: .down)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                        self.imageOffset = .zero
                        self.imageRotation = 0
                    }
                }
            }
            
            if self.isScrollingGestureActive {
                return nil
            }
            
            return event
        }
    }
}

struct LiquidCircularButton: View {
    let key: String
    let icon: String
    let badgeColor: Color
    let helpText: String
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.black) 
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(isHovering ? Color.black.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        
        .glassEffect(.clear, in: Circle())
        .contentShape(Circle()) 
        .scaleEffect(isHovering ? 1.05 : 1.0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .overlay(
            
            Text(key)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(badgeColor)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .shadow(color: badgeColor.opacity(0.3), radius: 2)
                .offset(x: 14, y: -14),
            alignment: .topTrailing
        )
        .help(helpText)
    }
}

struct LiquidNavButton: View {
    let key: String
    let icon: String
    let helpText: String
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.black) 
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(isHovering ? Color.black.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .glassEffect(.clear, in: Circle())
        .contentShape(Circle()) 
        .scaleEffect(isHovering ? 1.05 : 1.0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .overlay(
            Text(key)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 2.5))
                .offset(x: 11, y: -11),
            alignment: .topTrailing
        )
        .help(helpText)
    }
}

struct FinishedPassView: View {
    let yesCount: Int
    let drillDownAction: () -> Void
    let goUpAction: (() -> Void)?
    let isQueueMode: Bool
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundColor(Color(red: 0.13, green: 0.77, blue: 0.37).opacity(0.85))
                .shadow(color: Color.green.opacity(0.1), radius: 8)
            
            VStack(spacing: 10) {
                Text("Folder Sorting Pass Complete!")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                
                Text("You've sorted all files in this directory.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 400)
            
            VStack(spacing: 12) {
                if isQueueMode && yesCount > 0 {
                    Button(action: drillDownAction) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.right.to.line.circle.fill")
                                .font(.system(size: 16))
                            Text("Drill Down: Filter the \(yesCount) Liked Photos (\(yesCount) remaining)")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .cornerRadius(10)
                        .shadow(color: Color.blue.opacity(0.2), radius: 4)
                    }
                    .buttonStyle(.plain)
                    
                    Text("This lets you refine your favorites without relativistic star ratings!")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                
                if let goUp = goUpAction {
                    Button(action: goUp) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.circle")
                            Text("Go Back to Parent Folder")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .cornerRadius(8)
                        .shadow(color: Color.black.opacity(0.04), radius: 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
            }
            .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SplitShape: Shape {
    var fraction: Double
    
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let splitX = rect.width * CGFloat(fraction)
        path.addRect(CGRect(x: splitX, y: 0, width: rect.width - splitX, height: rect.height))
        return path
    }
}

struct ComparisonSliderView: View {
    let original: NSImage
    let denoised: NSImage
    @Binding var splitFraction: Double
    @Binding var zoomEnabled: Bool
    @State private var isDragging = false
    @State private var dragStartFraction: Double = 0.5
    
    @State private var hoverLocation: CGPoint = .zero
    @State private var isHovering = false
    
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let dividerX = CGFloat(splitFraction) * size.width
            
            ZStack(alignment: .leading) {
                
                Image(nsImage: original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                
                Image(nsImage: denoised)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .clipShape(SplitShape(fraction: splitFraction))
                
                ZStack {
                    
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 2)
                        .shadow(color: .black.opacity(0.2), radius: 2)
                    
                    Circle()
                        .fill(Color.white)
                        .frame(width: 32, height: 32)
                        .shadow(color: .black.opacity(0.15), radius: 4)
                        .overlay(
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.gray)
                        )
                }
                .frame(width: 44, height: size.height)
                .contentShape(Rectangle())
                .position(x: dividerX, y: size.height / 2)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                dragStartFraction = splitFraction
                                isDragging = true
                            }
                            let deltaFraction = Double(value.translation.width / size.width)
                            splitFraction = max(0.0, min(1.0, dragStartFraction + deltaFraction))
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
                
                if zoomEnabled && isHovering && !isDragging {
                    
                    Circle()
                        .stroke(Color.white, lineWidth: 1.5)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .frame(width: 10, height: 10)
                        .position(hoverLocation)
                        .allowsHitTesting(false)
                    
                    let magnifierSize: CGFloat = 220
                    let zoomFactor: CGFloat = 4.0
                    
                    let magnifyLocationX = hoverLocation.x
                    let magnifyLocationY = hoverLocation.y
                    
                    let magnifierSplitFraction = 0.5
                    
                    let popupX = max(magnifierSize / 2 + 10, min(size.width - magnifierSize / 2 - 10, magnifyLocationX))
                    let popupY = max(magnifierSize / 2 + 10, min(size.height - magnifierSize / 2 - 10, magnifyLocationY - 130))
                    
                    ZStack {
                        
                        Image(nsImage: original)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size.width, height: size.height)
                            .scaleEffect(zoomFactor)
                            .offset(x: (size.width / 2.0 - magnifyLocationX) * zoomFactor, y: (size.height / 2.0 - magnifyLocationY) * zoomFactor)
                            .frame(width: magnifierSize, height: magnifierSize)
                            .clipped()
                        
                        Image(nsImage: denoised)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size.width, height: size.height)
                            .scaleEffect(zoomFactor)
                            .offset(x: (size.width / 2.0 - magnifyLocationX) * zoomFactor, y: (size.height / 2.0 - magnifyLocationY) * zoomFactor)
                            .frame(width: magnifierSize, height: magnifierSize)
                            .clipShape(SplitShape(fraction: magnifierSplitFraction))
                    }
                    .frame(width: magnifierSize, height: magnifierSize)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.4), .white.opacity(0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 16))
                            .shadow(color: Color.black.opacity(0.15), radius: 10, y: 6)
                    )
                    
                    .overlay(
                        Group {
                            if magnifierSplitFraction > 0.0 && magnifierSplitFraction < 1.0 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.8))
                                    .frame(width: 1.5)
                                    .offset(x: -magnifierSize/2 + CGFloat(magnifierSplitFraction) * magnifierSize)
                            }
                        }
                    )
                    .frame(width: magnifierSize, height: magnifierSize)
                    .position(x: popupX, y: popupY)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                zoomEnabled.toggle()
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    self.hoverLocation = location
                    self.isHovering = true
                case .ended:
                    self.isHovering = false
                }
            }
        }
    }
}

struct SingleImageLoupeView: View {
    let image: NSImage
    @Binding var zoomEnabled: Bool

    @State private var hoverLocation: CGPoint = .zero
    @State private var isHovering = false
    
    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack {
                
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)

                if zoomEnabled && isHovering {
                    let magnifierSize: CGFloat = 220
                    let zoomFactor: CGFloat = 4.0

                    let magnifyLocationX = hoverLocation.x
                    let magnifyLocationY = hoverLocation.y

                    let popupX = max(magnifierSize / 2 + 10, min(size.width - magnifierSize / 2 - 10, magnifyLocationX))
                    let popupY = max(magnifierSize / 2 + 10, min(size.height - magnifierSize / 2 - 10, magnifyLocationY - 130))

                    Circle()
                        .stroke(Color.white, lineWidth: 1.5)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .frame(width: 10, height: 10)
                        .position(hoverLocation)
                        .allowsHitTesting(false)

                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(zoomFactor)
                        .offset(
                            x: (size.width / 2.0 - magnifyLocationX) * zoomFactor,
                            y: (size.height / 2.0 - magnifyLocationY) * zoomFactor
                        )
                        .frame(width: magnifierSize, height: magnifierSize)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.4), .white.opacity(0.15)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 16))
                                .shadow(color: Color.black.opacity(0.15), radius: 10, y: 6)
                        )
                        .frame(width: magnifierSize, height: magnifierSize)
                        .position(x: popupX, y: popupY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                zoomEnabled.toggle()
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    self.hoverLocation = location
                    self.isHovering = true
                case .ended:
                    self.isHovering = false
                }
            }
        }
    }
}

struct SeparatorShapeStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        Color.black.opacity(0.06)
    }
}

struct ProgressProgressBar: View {
    let current: Int
    let total: Int
    
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let progress = total > 0 ? CGFloat(current) / CGFloat(total) : 0
                
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.black.opacity(0.04))
                    
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.6), Color.blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: w * progress)
                }
            }
            .frame(height: 4)
            
            HStack {
                Text("Sorted \(current) of \(total) photos")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(total > 0 ? (current * 100 / total) : 0)% Complete")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
        }
        .frame(height: 24)
        .padding(.vertical, 8)
    }
}

struct EmptyStateView: View {
    let selectAction: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundColor(.gray.opacity(0.4))
            
            VStack(spacing: 8) {
                Text("Let's sort some photos!")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Select a folder containing photos. If denoised counterparts exist (e.g. filename-denoise.dng), PhotoSorter will automatically overlay them for comparison.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 450)
            }
            
            Button(action: selectAction) {
                Text("Open Folder")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(40)
    }
}

struct MinimalistIconView: View {
    var body: some View {
        ZStack {
            
            Color.clear
            
            ZStack {
                
                RoundedRectangle(cornerRadius: 88, style: .continuous)
                    .fill(Color.black.opacity(0.04))
                    .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 8)
                
                RoundedRectangle(cornerRadius: 88, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.25), .white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                RoundedRectangle(cornerRadius: 88, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), Color.white.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                
                RoundedRectangle(cornerRadius: 88, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.85),
                                .white.opacity(0.3),
                                .white.opacity(0.1),
                                .white.opacity(0.5)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 4
                    )
                
                ZStack {
                    
                    Path { path in
                        path.move(to: CGPoint(x: 160, y: 115))
                        path.addLine(to: CGPoint(x: 240, y: 115))
                        path.addLine(to: CGPoint(x: 255, y: 140))
                        path.addLine(to: CGPoint(x: 290, y: 140))
                        
                        path.addQuadCurve(to: CGPoint(x: 300, y: 150), control: CGPoint(x: 300, y: 140))
                        path.addLine(to: CGPoint(x: 300, y: 255))
                        path.addQuadCurve(to: CGPoint(x: 290, y: 265), control: CGPoint(x: 300, y: 265))
                        
                        path.addLine(to: CGPoint(x: 110, y: 265))
                        path.addQuadCurve(to: CGPoint(x: 100, y: 255), control: CGPoint(x: 100, y: 265))
                        
                        path.addLine(to: CGPoint(x: 100, y: 150))
                        path.addQuadCurve(to: CGPoint(x: 110, y: 140), control: CGPoint(x: 100, y: 140))
                        path.addLine(to: CGPoint(x: 145, y: 140))
                        path.closeSubpath()
                    }
                    .stroke(Color.white.opacity(0.85), lineWidth: 10)
                    
                    Circle()
                        .stroke(Color.white.opacity(0.85), lineWidth: 10)
                        .frame(width: 100, height: 100)
                        .offset(y: 2.5)
                    
                    Circle()
                        .stroke(Color.white.opacity(0.85), lineWidth: 6)
                        .frame(width: 56, height: 56)
                        .offset(y: 2.5)
                    
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 14, height: 14)
                        .offset(x: 75, y: -45)
                }
            }
            .frame(width: 400, height: 400) 
        }
        .frame(width: 512, height: 512)
    }
}

struct MiniIconView: View {
    var body: some View {
        ZStack {
            
            Circle()
                .stroke(Color.black.opacity(0.85), lineWidth: 2.5)
                .frame(width: 26, height: 26)
            
            Circle()
                .stroke(Color.black.opacity(0.85), lineWidth: 1.8)
                .frame(width: 18, height: 18)
            
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: 5.5, height: 5.5)
                .offset(x: 3.6, y: -3.6)
        }
        .frame(width: 30, height: 30)
    }
}
