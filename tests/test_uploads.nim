## Comprehensive test suite for upload functionality
## Tests streaming uploads, TUS protocol, range requests, and checksums

import std/[unittest, strutils, strformat, os, times, sha1, base64, tables]
import ../src/mummy, ../src/mummy/routers, ../src/mummy/uploads, ../src/mummy/tus, ../src/mummy/ranges

suite "Upload Infrastructure Tests":

  setup:
    # Create test directories
    if not dirExists("test_uploads"):
      createDir("test_uploads")
    if not dirExists("test_uploads/tmp"):
      createDir("test_uploads/tmp")

  teardown:
    # Clean up test files
    if dirExists("test_uploads"):
      removeDir("test_uploads")

  test "Upload configuration validation":
    var config = defaultUploadConfig()
    config.uploadDir = "test_uploads"
    config.tempDir = "test_uploads/tmp"
    
    expect(UploadError):
      var badConfig = defaultUploadConfig()
      badConfig.uploadDir = ""
      validateUploadConfig(badConfig)
    
    expect(UploadError):
      var badConfig = defaultUploadConfig()
      badConfig.bufferSize = 0
      validateUploadConfig(badConfig)

  test "Upload ID generation":
    let id1 = generateUploadId()
    let id2 = generateUploadId()
    
    check id1 != id2
    check id1.len == 32
    check id2.len == 32

  test "Filename sanitization":
    check sanitizeFilename("test.txt") == "test.txt"
    check sanitizeFilename("../../../etc/passwd") == "____etc_passwd"
    check sanitizeFilename("file/with\\path:separators") == "file_with_path_separators"
    check sanitizeFilename("") == "upload_"
    check sanitizeFilename(".hidden") == "upload_.hidden"

  test "Upload session creation":
    var config = defaultUploadConfig()
    config.uploadDir = "test_uploads"
    config.tempDir = "test_uploads/tmp"
    
    let uploadId = generateUploadId()
    let session = newUploadSession(uploadId, "test.txt", config, 1024)
    
    check session.id == uploadId
    check session.filename == "test.txt"
    check session.totalSize == 1024
    check session.bytesReceived == 0
    check session.status == UploadPending

  test "Upload manager operations":
    var config = defaultUploadConfig()
    config.uploadDir = "test_uploads"
    config.tempDir = "test_uploads/tmp"
    
    var manager = newUploadManager(config)
    
    # Test upload creation
    let uploadId = manager.createUpload("test.txt", 1, 1024)
    check uploadId.len > 0
    
    # Test upload retrieval
    let upload = manager.getUpload(uploadId)
    check upload != nil
    check upload[].filename == "test.txt"
    
    # Test upload removal
    manager.removeUpload(uploadId)
    let removedUpload = manager.getUpload(uploadId)
    check removedUpload == nil

suite "TUS Protocol Tests":

  setup:
    if not dirExists("test_uploads"):
      createDir("test_uploads")
    if not dirExists("test_uploads/tmp"):
      createDir("test_uploads/tmp")

  teardown:
    if dirExists("test_uploads"):
      removeDir("test_uploads")

  test "TUS configuration defaults":
    let config = defaultTUSConfig()
    check config.version == TUS_1_0
    check TUSCreation in config.supportedExtensions
    check TUSChecksum in config.supportedExtensions
    check config.enableChecksum == true

  test "TUS header parsing":
    var headers: HttpHeaders
    headers["Tus-Resumable"] = "1.0.0"
    headers["Upload-Length"] = "1024"
    headers["Upload-Offset"] = "512"
    headers["Upload-Metadata"] = "filename " & base64.encode("test.txt")
    
    let tusHeaders = parseTUSHeaders(headers)
    check tusHeaders.tusResumable == "1.0.0"
    check tusHeaders.uploadLength == 1024
    check tusHeaders.uploadOffset == 512
    check tusHeaders.uploadMetadata.getOrDefault("filename", "") == "test.txt"

  test "TUS request validation":
    let config = defaultTUSConfig()
    
    # Test valid POST request
    var tusHeaders = TUSHeaders(
      tusResumable: "1.0.0",
      uploadLength: 1024,
      uploadOffset: -1
    )
    var result = validateTUSRequest("POST", tusHeaders, config)
    check result.valid == true
    
    # Test invalid version
    tusHeaders.tusResumable = "2.0.0"
    result = validateTUSRequest("POST", tusHeaders, config)
    check result.valid == false
    
    # Test missing upload length
    tusHeaders.tusResumable = "1.0.0"
    tusHeaders.uploadLength = -1
    result = validateTUSRequest("POST", tusHeaders, config)
    check result.valid == false

  test "TUS response creation":
    let config = defaultTUSConfig()
    let response = createTUSResponse(201, config, "upload123", 0, 1024)
    
    check response.statusCode == 201
    check response.headers["Tus-Resumable"] == "1.0.0"
    check response.headers["Location"] == "/files/upload123"
    check response.headers["Upload-Offset"] == "0"
    check response.headers["Upload-Length"] == "1024"

suite "HTTP Range Request Tests":

  test "Range header parsing":
    # Test single range
    let range1 = parseRangeHeader("bytes=200-1023")
    check range1.unit == RangeBytes
    check range1.ranges.len == 1
    check range1.ranges[0].start == 200
    check range1.ranges[0].`end` == 1023
    
    # Test multiple ranges
    let range2 = parseRangeHeader("bytes=0-499,1000-1499")
    check range2.ranges.len == 2
    check range2.ranges[0].start == 0
    check range2.ranges[0].`end` == 499
    check range2.ranges[1].start == 1000
    check range2.ranges[1].`end` == 1499
    
    # Test suffix range
    let range3 = parseRangeHeader("bytes=-500")
    check range3.ranges[0].start == -1
    check range3.ranges[0].`end` == 500
    
    # Test open range
    let range4 = parseRangeHeader("bytes=500-")
    check range4.ranges[0].start == 500
    check range4.ranges[0].`end` == -1

  test "Range normalization":
    let contentLength = 2000
    
    # Test normal range
    var range = ByteRange(start: 100, `end`: 199)
    let normalized1 = normalizeRange(range, contentLength)
    check normalized1.start == 100
    check normalized1.`end` == 199
    
    # Test suffix range
    range = ByteRange(start: -1, `end`: 200)
    let normalized2 = normalizeRange(range, contentLength)
    check normalized2.start == 1800  # 2000 - 200
    check normalized2.`end` == 1999  # 2000 - 1
    
    # Test open range
    range = ByteRange(start: 1500, `end`: -1)
    let normalized3 = normalizeRange(range, contentLength)
    check normalized3.start == 1500
    check normalized3.`end` == 1999

  test "Upload range parsing":
    # Test valid upload range
    let (start, `end`, total) = parseUploadRange("bytes 200-1023/2048")
    check start == 200
    check `end` == 1023
    check total == 2048
    
    # Test unknown total
    let (start2, end2, total2) = parseUploadRange("bytes 0-1023/*")
    check start2 == 0
    check end2 == 1023
    check total2 == -1

  test "Content-Range formatting":
    let contentRange = ContentRange(
      unit: RangeBytes,
      start: 200,
      `end`: 1023,
      totalLength: 2048
    )
    let formatted = formatContentRange(contentRange)
    check formatted == "bytes 200-1023/2048"

suite "Checksum and Integrity Tests":

  setup:
    if not dirExists("test_uploads"):
      createDir("test_uploads")
    if not dirExists("test_uploads/tmp"):
      createDir("test_uploads/tmp")

  teardown:
    if dirExists("test_uploads"):
      removeDir("test_uploads")

  test "SHA1 checksum calculation":
    let testData = "Hello, World!"
    let expectedHash = $secureHash(testData)
    
    var config = defaultUploadConfig()
    config.uploadDir = "test_uploads"
    config.tempDir = "test_uploads/tmp"
    
    var manager = newUploadManager(config)
    let uploadId = manager.createUpload("test.txt", 1, testData.len)
    let upload = manager.getUpload(uploadId)
    
    upload[].setExpectedChecksum(expectedHash)
    upload[].openForWriting()
    upload[].writeChunk(testData.toOpenArrayByte(0, testData.len - 1))
    upload[].completeUpload()
    
    check upload[].status == UploadCompleted
    check upload[].actualChecksum.toLowerAscii() == expectedHash.toLowerAscii()

  test "Checksum mismatch detection":
    let testData = "Hello, World!"
    let wrongHash = "wrong_checksum"
    
    var config = defaultUploadConfig()
    config.uploadDir = "test_uploads"
    config.tempDir = "test_uploads/tmp"
    
    var manager = newUploadManager(config)
    let uploadId = manager.createUpload("test.txt", 1, testData.len)
    let upload = manager.getUpload(uploadId)
    
    upload[].setExpectedChecksum(wrongHash)
    upload[].openForWriting()
    upload[].writeChunk(testData.toOpenArrayByte(0, testData.len - 1))
    
    expect(UploadError):
      upload[].completeUpload()

suite "Error Handling and Edge Cases":

  setup:
    if not dirExists("test_uploads"):
      createDir("test_uploads")
    if not dirExists("test_uploads/tmp"):
      createDir("test_uploads/tmp")

  teardown:
    if dirExists("test_uploads"):
      removeDir("test_uploads")

  test "File size limit enforcement":
    var config = defaultUploadConfig()
    config.uploadDir = "test_uploads"
    config.tempDir = "test_uploads/tmp"
    config.maxFileSize = 100  # Very small limit
    
    var manager = newUploadManager(config)
    
    expect(UploadError):
      discard manager.createUpload("large.txt", 1, 1000)  # Exceeds limit

  test "Concurrent upload limit":
    var config = defaultUploadConfig()
    config.uploadDir = "test_uploads"
    config.tempDir = "test_uploads/tmp"
    config.maxConcurrentUploads = 1
    
    var manager = newUploadManager(config)
    
    # First upload should succeed
    let uploadId1 = manager.createUpload("file1.txt", 1, 100)
    check uploadId1.len > 0
    
    # Second upload should fail due to limit
    expect(UploadError):
      discard manager.createUpload("file2.txt", 1, 100)

  test "Invalid range handling":
    expect(ranges.RangeError):
      discard parseRangeHeader("invalid-range")
    
    expect(ranges.RangeError):
      discard parseRangeHeader("bytes=")
    
    expect(ranges.RangeError):
      discard parseRangeHeader("bytes=1000-500")  # Start > end

  test "Upload session expiration":
    var config = defaultUploadConfig()
    config.uploadDir = "test_uploads"
    config.tempDir = "test_uploads/tmp"
    config.uploadTimeout = 0.1  # Very short timeout
    
    var manager = newUploadManager(config)
    let uploadId = manager.createUpload("test.txt", 1, 100)
    let upload = manager.getUpload(uploadId)
    
    # Simulate time passing
    sleep(200)  # Wait longer than timeout
    
    check upload[].isExpired(config.uploadTimeout) == true

when isMainModule:
  # Run the tests
  echo "Running upload functionality tests..."