import Foundation
import Network
import AppKit

public final class DirectHTTPHandler: @unchecked Sendable {
    private static var activeHandlers: [String: DirectHTTPHandler] = [:]
    private static let lock = NSLock()

    private let id: String
    private var fileWriter: StreamingFileWriter?
    private var totalExpectedBytes: Int64 = 0
    private var bytesReceivedSoFar: Int64 = 0

    private init(id: String) {
        self.id = id
    }

    public static func isHTTPRequest(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        // "GET "
        if data[0] == 0x47 && data[1] == 0x45 && data[2] == 0x54 && data[3] == 0x20 { return true }
        // "POST"
        if data[0] == 0x50 && data[1] == 0x4F && data[2] == 0x53 && data[3] == 0x54 { return true }
        // "HEAD"
        if data[0] == 0x48 && data[1] == 0x45 && data[2] == 0x41 && data[3] == 0x44 { return true }
        // "OPTI"
        if data[0] == 0x4F && data[1] == 0x50 && data[2] == 0x54 && data[3] == 0x49 { return true }
        // "PUT "
        if data[0] == 0x50 && data[1] == 0x55 && data[2] == 0x54 && data[3] == 0x20 { return true }
        return false
    }

    public static func handle(connection: NWConnection, initialBytes: Data) {
        let id = UUID().uuidString
        let handler = DirectHTTPHandler(id: id)
        lock.lock()
        activeHandlers[id] = handler
        lock.unlock()

        handler.process(connection: connection, initialBytes: initialBytes)
    }

    private func cleanup(connection: NWConnection) {
        connection.cancel()
        DirectHTTPHandler.lock.lock()
        DirectHTTPHandler.activeHandlers.removeValue(forKey: self.id)
        DirectHTTPHandler.lock.unlock()
    }

    private func process(connection: NWConnection, initialBytes: Data) {
        self.readHeaders(connection: connection, buffer: initialBytes)
    }

    private func readHeaders(connection: NWConnection, buffer: Data) {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        if let range = buffer.range(of: separator) {
            let headerData = buffer.subdata(in: 0..<range.lowerBound)
            let bodyData = buffer.subdata(in: range.upperBound..<buffer.count)
            self.routeRequest(connection: connection, headerData: headerData, bodyData: bodyData)
        } else {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
                guard let self = self else { return }
                guard let content = content, !content.isEmpty, error == nil else {
                    self.cleanup(connection: connection)
                    return
                }
                var newBuffer = buffer
                newBuffer.append(content)
                self.readHeaders(connection: connection, buffer: newBuffer)
            }
        }
    }

    private func routeRequest(connection: NWConnection, headerData: Data, bodyData: Data) {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            cleanup(connection: connection)
            return
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            cleanup(connection: connection)
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            cleanup(connection: connection)
            return
        }

        let method = parts[0].uppercased()
        let path = parts[1]

        if method == "GET" {
            serveWebUI(connection: connection, headOnly: false)
        } else if method == "HEAD" {
            serveWebUI(connection: connection, headOnly: true)
        } else if method == "OPTIONS" {
            serveOptions(connection: connection)
        } else if method == "POST" && path.starts(with: "/upload") {
            startStreamingUpload(connection: connection, path: path, lines: lines, bodyData: bodyData)
        } else {
            serveNotFound(connection: connection)
        }
    }

    private func serveWebUI(connection: NWConnection, headOnly: Bool) {
        let html = DirectHTTPHandler.webDropHTML
        guard let bodyData = html.data(using: .utf8) else {
            cleanup(connection: connection)
            return
        }
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var resp = headers.data(using: .utf8)!
        if !headOnly {
            resp.append(bodyData)
        }
        connection.send(content: resp, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.cleanup(connection: connection)
        })
    }

    private func serveOptions(connection: NWConnection) {
        let resp = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, HEAD, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: resp.data(using: .utf8)!, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.cleanup(connection: connection)
        })
    }

    private func serveNotFound(connection: NWConnection) {
        let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: resp.data(using: .utf8)!, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.cleanup(connection: connection)
        })
    }

    private func startStreamingUpload(connection: NWConnection, path: String, lines: [String], bodyData: Data) {
        var filename = "shared_file_\(Int(Date().timeIntervalSince1970))"
        if let queryIndex = path.firstIndex(of: "?") {
            let queryString = String(path[path.index(after: queryIndex)...])
            let queryItems = queryString.components(separatedBy: "&")
            for item in queryItems {
                let pair = item.components(separatedBy: "=")
                if pair.count == 2 && pair[0] == "filename" {
                    if let decoded = pair[1].removingPercentEncoding {
                        filename = decoded
                    }
                }
            }
        }

        var contentLength: Int64 = 0
        for line in lines {
            let lower = line.lowercased()
            if lower.starts(with: "content-length:") {
                let valStr = line.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                contentLength = Int64(valStr) ?? 0
            }
        }

        self.totalExpectedBytes = contentLength
        self.bytesReceivedSoFar = 0

        guard let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            cleanup(connection: connection)
            return
        }

        do {
            let fileId = Int64(Date().timeIntervalSince1970 * 1000)
            let meta = FileMetadata(id: fileId, name: filename, size: contentLength, mimeType: "application/octet-stream")
            let writer = try StreamingFileWriter(metadata: meta, destinationDirectory: downloadsDir)
            self.fileWriter = writer

            if !bodyData.isEmpty {
                try writer.writeChunk(bodyData, offset: 0)
                bytesReceivedSoFar += Int64(bodyData.count)
            }

            if bytesReceivedSoFar >= totalExpectedBytes && totalExpectedBytes > 0 {
                self.finishUpload(connection: connection)
            } else {
                self.receiveUploadChunks(connection: connection)
            }
        } catch {
            print("[DirectHTTPHandler] Upload init error: \(error)")
            self.fileWriter?.abort()
            self.cleanup(connection: connection)
        }
    }

    private func receiveUploadChunks(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let content = content, !content.isEmpty {
                do {
                    try self.fileWriter?.writeChunk(content, offset: self.bytesReceivedSoFar)
                    self.bytesReceivedSoFar += Int64(content.count)
                } catch {
                    print("[DirectHTTPHandler] Write chunk error: \(error)")
                    self.fileWriter?.abort()
                    self.cleanup(connection: connection)
                    return
                }
            }

            if self.bytesReceivedSoFar >= self.totalExpectedBytes && self.totalExpectedBytes > 0 {
                self.finishUpload(connection: connection)
            } else if isComplete || error != nil {
                if self.bytesReceivedSoFar >= self.totalExpectedBytes && self.totalExpectedBytes > 0 {
                    self.finishUpload(connection: connection)
                } else {
                    self.fileWriter?.abort()
                    self.cleanup(connection: connection)
                }
            } else {
                self.receiveUploadChunks(connection: connection)
            }
        }
    }

    private func finishUpload(connection: NWConnection) {
        do {
            if let finalURL = try fileWriter?.finalizeTransfer() {
                let filename = finalURL.lastPathComponent
                print("[DirectHTTPHandler] File saved successfully: \(finalURL.path)")

                // Deliver macOS User Notification
                DispatchQueue.main.async {
                    let center = NSUserNotificationCenter.default
                    let notification = NSUserNotification()
                    notification.title = "Direct Fast Drop Complete"
                    notification.informativeText = "Saved '\(filename)' to Downloads"
                    notification.soundName = NSUserNotificationDefaultSoundName
                    center.deliver(notification)
                }

                let respBody = "{\"status\":\"ok\",\"file\":\"\(filename)\"}".data(using: .utf8)!
                let respHeaders = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(respBody.count)\r\nConnection: close\r\n\r\n"
                var fullResp = respHeaders.data(using: .utf8)!
                fullResp.append(respBody)
                connection.send(content: fullResp, isComplete: true, completion: .contentProcessed { [weak self] _ in
                    self?.cleanup(connection: connection)
                })
            }
        } catch {
            print("[DirectHTTPHandler] Finalize error: \(error)")
            self.fileWriter?.abort()
            self.cleanup(connection: connection)
        }
    }

    private static let webDropHTML: String = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Android to Mac Drop</title>
    <style>
      :root { --primary: #2563eb; --bg: #f8fafc; --card: #ffffff; --text: #0f172a; --subtext: #64748b; --border: #e2e8f0; }
      @media (prefers-color-scheme: dark) {
        :root { --bg: #0f172a; --card: #1e293b; --text: #f8fafc; --subtext: #94a3b8; --border: #334155; }
      }
      body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 20px; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 90vh; }
      .card { background: var(--card); border: 1px solid var(--border); border-radius: 20px; padding: 28px; width: 100%; max-width: 420px; box-shadow: 0 10px 25px -5px rgba(0,0,0,0.1); text-align: center; box-sizing: border-box; }
      .badge { display: inline-flex; align-items: center; gap: 6px; padding: 6px 14px; border-radius: 9999px; background: #ecfdf5; color: #059669; font-size: 13px; font-weight: 600; margin-bottom: 16px; }
      .badge-dot { width: 8px; height: 8px; border-radius: 50%; background: #10b981; }
      h1 { font-size: 22px; margin: 0 0 8px 0; font-weight: 700; }
      p { font-size: 14px; color: var(--subtext); margin: 0 0 24px 0; line-height: 1.5; }
      .dropzone { border: 2px dashed var(--primary); border-radius: 16px; padding: 36px 20px; background: rgba(37, 99, 235, 0.04); cursor: pointer; transition: all 0.2s ease; margin-bottom: 20px; }
      .dropzone:active { transform: scale(0.98); }
      .drop-icon { width: 48px; height: 48px; fill: var(--primary); margin-bottom: 12px; }
      .drop-text { font-size: 16px; font-weight: 600; color: var(--primary); }
      .drop-hint { font-size: 12px; color: var(--subtext); margin-top: 4px; }
      #fileInput { display: none; }
      .progress-wrap { display: none; margin-top: 20px; text-align: left; }
      .progress-bar-bg { width: 100%; height: 10px; background: var(--border); border-radius: 9999px; overflow: hidden; margin-top: 8px; }
      .progress-bar-fill { width: 0%; height: 100%; background: var(--primary); transition: width 0.1s ease; }
      .stats-row { display: flex; justify-content: space-between; font-size: 12px; color: var(--subtext); margin-top: 6px; font-variant-numeric: tabular-nums; }
      .success-box { display: none; background: #ecfdf5; border: 1px solid #a7f3d0; border-radius: 12px; padding: 16px; color: #065f46; font-size: 14px; margin-top: 20px; }
    </style>
    </head>
    <body>
    <div class="card">
      <div class="badge"><span class="badge-dot"></span> DIRECT WI-FI CONNECTED</div>
      <h1>Fast Drop to Mac</h1>
      <p>High-speed direct streaming (1GB - 3GB) over local Wi-Fi / Hotspot directly to your Mac Downloads.</p>

      <div class="dropzone" id="dropzone" onclick="document.getElementById('fileInput').click()">
        <svg class="drop-icon" viewBox="0 0 24 24"><path d="M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z"/></svg>
        <div class="drop-text">Tap to Select 1GB - 3GB File</div>
        <div class="drop-hint">Videos, Large Archives, Photos</div>
      </div>
      <input type="file" id="fileInput" onchange="handleFileSelect(this.files)">

      <div class="progress-wrap" id="progressWrap">
        <div style="display:flex; justify-content:space-between; font-size:13px; font-weight:600">
          <span id="fileName" style="max-width:200px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">Uploading...</span>
          <span id="percent">0%</span>
        </div>
        <div class="progress-bar-bg"><div class="progress-bar-fill" id="progressFill"></div></div>
        <div class="stats-row">
          <span id="speed">0 MB/s</span>
          <span id="transferred">0 / 0 MB</span>
        </div>
      </div>

      <div class="success-box" id="successBox">
        <strong>&#x2714; Transfer Complete!</strong>
        <div style="margin-top:4px" id="savedName">File saved to Mac Downloads.</div>
      </div>
    </div>

    <script>
    function formatBytes(bytes) {
      if (bytes === 0) return '0 B';
      const k = 1024;
      const sizes = ['B', 'KB', 'MB', 'GB'];
      const i = Math.floor(Math.log(bytes) / Math.log(k));
      return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
    }

    function handleFileSelect(files) {
      if (!files || files.length === 0) return;
      const file = files[0];

      const dropzone = document.getElementById('dropzone');
      const progressWrap = document.getElementById('progressWrap');
      const progressFill = document.getElementById('progressFill');
      const percent = document.getElementById('percent');
      const speedEl = document.getElementById('speed');
      const transferredEl = document.getElementById('transferred');
      const fileName = document.getElementById('fileName');
      const successBox = document.getElementById('successBox');

      dropzone.style.display = 'none';
      successBox.style.display = 'none';
      progressWrap.style.display = 'block';
      fileName.textContent = file.name;

      let startTime = Date.now();
      let lastLoaded = 0;
      let lastTime = startTime;

      const xhr = new XMLHttpRequest();
      xhr.open('POST', '/upload?filename=' + encodeURIComponent(file.name), true);
      xhr.setRequestHeader('Content-Type', 'application/octet-stream');

      xhr.upload.onprogress = function(e) {
        if (e.lengthComputable) {
          const now = Date.now();
          const elapsed = (now - lastTime) / 1000;
          if (elapsed >= 0.2) {
            const bytesDiff = e.loaded - lastLoaded;
            const currentSpeed = (bytesDiff / elapsed) / (1024 * 1024);
            speedEl.textContent = currentSpeed.toFixed(1) + ' MB/s';
            lastLoaded = e.loaded;
            lastTime = now;
          }
          const pct = Math.round((e.loaded / e.total) * 100);
          progressFill.style.width = pct + '%';
          percent.textContent = pct + '%';
          transferredEl.textContent = formatBytes(e.loaded) + ' / ' + formatBytes(e.total);
        }
      };

      xhr.onload = function() {
        progressWrap.style.display = 'none';
        dropzone.style.display = 'block';
        if (xhr.status === 200) {
          successBox.style.display = 'block';
          document.getElementById('savedName').textContent = file.name + ' (' + formatBytes(file.size) + ') saved to Downloads!';
        } else {
          alert('Upload failed: HTTP ' + xhr.status);
        }
      };

      xhr.onerror = function() {
        progressWrap.style.display = 'none';
        dropzone.style.display = 'block';
        alert('Transfer error occurred. Ensure Wi-Fi stays connected.');
      };

      xhr.send(file);
    }
    </script>
    </body>
    </html>
    """
}
