import Foundation

struct MoveRecord: Identifiable {
    let id = UUID()
    let photoItem: PhotoItem
    let index: Int 
    let targetFolder: String 
    let fileMoves: [(from: URL, to: URL)] 
    let selectedVersionDenoised: Bool 
}

class FileManagerQueue: ObservableObject {
    @Published var undoStack: [MoveRecord] = []
    @Published var isOperating: Bool = false
    
    private let fileQueue = DispatchQueue(label: "com.rshah.PhotoSorter.filemanager", qos: .utility)
    
    func sortPhoto(
        item: PhotoItem,
        atIndex index: Int,
        action: String, 
        baseDir: URL,
        completion: @escaping (MoveRecord?) -> Void
    ) {
        fileQueue.async {
            let fileManager = FileManager.default
            let yesDir = baseDir.appendingPathComponent("Yes")
            let noDir = baseDir.appendingPathComponent("No")
            let blurryDir = baseDir.appendingPathComponent("Blurry")
            
            do {
                if !fileManager.fileExists(atPath: yesDir.path) {
                    try fileManager.createDirectory(at: yesDir, withIntermediateDirectories: true, attributes: nil)
                }
                if !fileManager.fileExists(atPath: noDir.path) {
                    try fileManager.createDirectory(at: noDir, withIntermediateDirectories: true, attributes: nil)
                }
                if !fileManager.fileExists(atPath: blurryDir.path) {
                    try fileManager.createDirectory(at: blurryDir, withIntermediateDirectories: true, attributes: nil)
                }
            } catch {
                print("Error creating directories: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            var moves: [(from: URL, to: URL)] = []
            
            if action == "Keep" {
                
            } else if action == "Restore" {
                
                moves.append((from: item.originalURL, to: baseDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                if let denoisedURL = item.denoisedURL {
                    moves.append((from: denoisedURL, to: baseDir.appendingPathComponent(denoisedURL.lastPathComponent)))
                }
            } else if action == "MoveToBlurry" {
                
                moves.append((from: item.originalURL, to: blurryDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                if let denoisedURL = item.denoisedURL {
                    moves.append((from: denoisedURL, to: blurryDir.appendingPathComponent(denoisedURL.lastPathComponent)))
                }
            } else if action == "MoveToNo" {
                
                moves.append((from: item.originalURL, to: noDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                if let denoisedURL = item.denoisedURL {
                    moves.append((from: denoisedURL, to: noDir.appendingPathComponent(denoisedURL.lastPathComponent)))
                }
            } else if action == "MoveToYes" {
                
                moves.append((from: item.originalURL, to: yesDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                if let denoisedURL = item.denoisedURL {
                    moves.append((from: denoisedURL, to: yesDir.appendingPathComponent(denoisedURL.lastPathComponent)))
                }
            } else if action == "Yes" {
                if item.denoisedURL != nil {
                    moves.append((from: item.originalURL, to: yesDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                    moves.append((from: item.denoisedURL!, to: yesDir.appendingPathComponent(item.denoisedURL!.lastPathComponent)))
                } else {
                    moves.append((from: item.originalURL, to: yesDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                }
            } else if action == "No" {
                moves.append((from: item.originalURL, to: noDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                if let denoisedURL = item.denoisedURL {
                    moves.append((from: denoisedURL, to: noDir.appendingPathComponent(denoisedURL.lastPathComponent)))
                }
            } else if action == "Blurry" {
                moves.append((from: item.originalURL, to: blurryDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                if let denoisedURL = item.denoisedURL {
                    moves.append((from: denoisedURL, to: blurryDir.appendingPathComponent(denoisedURL.lastPathComponent)))
                }
            } else if item.denoisedURL != nil {
                if action == "AcceptLeft" {
                    
                    moves.append((from: item.originalURL, to: yesDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                    moves.append((from: item.denoisedURL!, to: blurryDir.appendingPathComponent(item.denoisedURL!.lastPathComponent)))
                } else if action == "AcceptRight" {
                    
                    moves.append((from: item.denoisedURL!, to: yesDir.appendingPathComponent(item.denoisedURL!.lastPathComponent)))
                    moves.append((from: item.originalURL, to: blurryDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                } else { 
                    
                    moves.append((from: item.originalURL, to: noDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                    moves.append((from: item.denoisedURL!, to: noDir.appendingPathComponent(item.denoisedURL!.lastPathComponent)))
                }
            } else {
                
                if action == "AcceptLeft" || action == "AcceptRight" {
                    moves.append((from: item.originalURL, to: yesDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                } else {
                    moves.append((from: item.originalURL, to: noDir.appendingPathComponent(item.originalURL.lastPathComponent)))
                }
            }
            
            var completedMoves: [(from: URL, to: URL)] = []
            
            for move in moves {
                do {
                    if fileManager.fileExists(atPath: move.to.path) {
                        try fileManager.removeItem(at: move.to)
                    }
                    try fileManager.moveItem(at: move.from, to: move.to)
                    completedMoves.append(move)
                } catch {
                    print("Error moving file \(move.from.lastPathComponent): \(error.localizedDescription)")
                }
            }
            
            if completedMoves.isEmpty {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            let record = MoveRecord(
                photoItem: item,
                index: index,
                targetFolder: action,
                fileMoves: completedMoves,
                selectedVersionDenoised: action == "AcceptRight"
            )
            
            DispatchQueue.main.async {
                self.undoStack.append(record)
                completion(record)
            }
        }
    }
    
    func undoLastMove(completion: @escaping (MoveRecord?) -> Void) {
        guard !undoStack.isEmpty else {
            completion(nil)
            return
        }
        
        let record = undoStack.removeLast()
        
        fileQueue.async {
            let fileManager = FileManager.default
            var successfulRestores = 0
            
            for move in record.fileMoves {
                do {
                    
                    let parentDir = move.from.deletingLastPathComponent()
                    if !fileManager.fileExists(atPath: parentDir.path) {
                        try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
                    }
                    
                    if fileManager.fileExists(atPath: move.from.path) {
                        try fileManager.removeItem(at: move.from)
                    }
                    
                    try fileManager.moveItem(at: move.to, to: move.from)
                    successfulRestores += 1
                } catch {
                    print("Error restoring file: \(error.localizedDescription)")
                }
            }
            
            DispatchQueue.main.async {
                if successfulRestores > 0 {
                    completion(record)
                } else {
                    completion(nil)
                }
            }
        }
    }
}
