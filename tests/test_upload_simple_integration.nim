## Simple integration test for upload functionality
## Tests upload components without running a full server

import std/[unittest, strutils, os, times, sha1, base64, tables, json]
import ../src/mummy, ../src/mummy/routers, ../src/mummy/uploads, ../src/mummy/tus, ../src/mummy/ranges

suite "Upload Simple Integration Tests":

  setup:
    # Create test directories
    if not dirExists("test_simple_uploads"):
      createDir("test_simple_uploads")
    if not dirExists("test_simple_uploads/tmp"):
      createDir("test_simple_uploads/tmp")

  teardown:
    # Clean up test files
    if dirExists("test_simple_uploads"):
      removeDir("test_simple_uploads")

  test "End-to-end upload session workflow":
    # Test complete upload workflow from creation to completion
    var config = defaultUploadConfig()
    config.uploadDir = "test_simple_uploads"
    config.tempDir = "test_simple_uploads/tmp"
    
    var manager = newUploadManager(config)
    
    let testData = "Integration test data for end-to-end workflow"
    let uploadId = manager.createUpload("test_workflow.txt", 1, testData.len)
    
    let upload = manager.getUpload(uploadId)
    check upload != nil
    
    # Test opening for writing
    upload[].openForWriting()
    check upload[].status == UploadInProgress
    
    # Test writing data in chunks
    let chunk1 = testData[0..9]
    let chunk2 = testData[10..19]
    let chunk3 = testData[20..^1]
    
    upload[].writeChunk(chunk1.toOpenArrayByte(0, chunk1.len - 1))
    check upload[].bytesReceived == chunk1.len
    
    upload[].writeChunk(chunk2.toOpenArrayByte(0, chunk2.len - 1))
    check upload[].bytesReceived == chunk1.len + chunk2.len
    
    upload[].writeChunk(chunk3.toOpenArrayByte(0, chunk3.len - 1))
    check upload[].bytesReceived == testData.len
    
    # Test completion
    upload[].completeUpload()
    check upload[].status == UploadCompleted
    check fileExists(upload[].finalPath)
    
    # Verify file contents
    let savedData = readFile(upload[].finalPath)
    check savedData == testData

  test "TUS protocol integration workflow":
    # Test complete TUS protocol workflow
    let config = defaultTUSConfig()
    var uploadManager = newUploadManager(defaultUploadConfig())
    uploadManager.config.uploadDir = "test_simple_uploads"
    uploadManager.config.tempDir = "test_simple_uploads/tmp"
    
    let testData = "TUS protocol integration test"
    let clientId = 123u64
    
    # Test TUS creation
    var tusHeaders = TUSHeaders(
      tusResumable: "1.0.0",
      uploadLength: testData.len,
      uploadOffset: -1
    )
    tusHeaders.uploadMetadata["filename"] = "tus_test.txt"
    
    let createResponse = handleTUSCreation(tusHeaders, uploadManager, clientId, config)
    check createResponse.statusCode == 201
    
    var location = ""
    for (key, value) in createResponse.headers:
      if key == "Location":
        location = value
        break
    check location.len > 0
    let uploadId = location.split("/")[^1]
    
    # Test TUS upload
    tusHeaders.uploadOffset = 0
    let uploadResponse = handleTUSUpload(tusHeaders, testData, uploadId, uploadManager, clientId, config)
    check uploadResponse.statusCode == 204
    check uploadResponse.headers["Upload-Offset"] == $testData.len
    
    # Test TUS status
    let statusResponse = handleTUSStatus(uploadId, uploadManager, clientId, config)
    check statusResponse.statusCode == 200
    check statusResponse.headers["Upload-Offset"] == $testData.len

  test "Range request integration workflow":
    # Test HTTP Range request workflow
    let testData = "Range request integration test data"
    let contentLength = testData.len
    
    # Test range parsing
    let rangeSpec = parseRangeHeader("bytes=0-9,20-29")
    check rangeSpec.ranges.len == 2
    
    # Test range normalization
    let range1 = normalizeRange(rangeSpec.ranges[0], contentLength)
    check range1.start == 0
    check range1.`end` == 9
    
    let range2 = normalizeRange(rangeSpec.ranges[1], contentLength)
    check range2.start == 20
    check range2.`end` == 29
    
    # Test upload range parsing
    let (start, `end`, total) = parseUploadRange("bytes 0-9/34")
    check start == 0
    check `end` == 9
    check total == 34
    
    # Test content range formatting
    let contentRange = ContentRange(
      unit: RangeBytes,
      start: 0,
      `end`: 9,
      totalLength: 34
    )
    let formatted = formatContentRange(contentRange)
    check formatted == "bytes 0-9/34"

  test "Upload with checksum verification workflow":
    # Test complete checksum verification workflow
    var config = defaultUploadConfig()
    config.uploadDir = "test_simple_uploads"
    config.tempDir = "test_simple_uploads/tmp"
    config.enableIntegrityCheck = true
    
    var manager = newUploadManager(config)
    
    let testData = "Checksum verification integration test"
    let expectedChecksum = $secureHash(testData)
    
    let uploadId = manager.createUpload("checksum_test.txt", 1, testData.len)
    let upload = manager.getUpload(uploadId)
    
    # Set expected checksum
    upload[].setExpectedChecksum(expectedChecksum)
    
    # Perform upload
    upload[].openForWriting()
    upload[].writeChunk(testData.toOpenArrayByte(0, testData.len - 1))
    upload[].completeUpload()
    
    check upload[].status == UploadCompleted
    check upload[].actualChecksum.toLowerAscii() == expectedChecksum.toLowerAscii()

  test "Range upload with multiple chunks":
    # Test range upload with multiple chunks
    var config = defaultUploadConfig()
    config.uploadDir = "test_simple_uploads"
    config.tempDir = "test_simple_uploads/tmp"
    config.enableRangeRequests = true
    
    var manager = newUploadManager(config)
    
    let testData = "Multi-chunk range upload test data"
    let uploadId = manager.createUpload("range_test.txt", 1, testData.len)
    let upload = manager.getUpload(uploadId)
    
    upload[].setRangeSupport(true)
    upload[].openForWriting()
    
    # Upload in chunks using range operations
    let chunk1 = testData[0..9]   # bytes 0-9
    let chunk2 = testData[10..19] # bytes 10-19
    let chunk3 = testData[20..^1] # bytes 20-end
    
    upload[].writeRangeChunk(chunk1.toOpenArrayByte(0, chunk1.len - 1), 0, 9)
    upload[].writeRangeChunk(chunk2.toOpenArrayByte(0, chunk2.len - 1), 10, 19)
    upload[].writeRangeChunk(chunk3.toOpenArrayByte(0, chunk3.len - 1), 20, testData.len - 1)
    
    upload[].completeUpload()
    check upload[].status == UploadCompleted
    
    # Verify file contents
    let savedData = readFile(upload[].finalPath)
    check savedData == testData

  test "Upload manager session tracking":
    # Test upload manager's session tracking capabilities
    var config = defaultUploadConfig()
    config.uploadDir = "test_simple_uploads"
    config.tempDir = "test_simple_uploads/tmp"
    config.maxConcurrentUploads = 2
    
    var manager = newUploadManager(config)
    
    let clientId = 456u64
    
    # Create multiple uploads for same client
    let uploadId1 = manager.createUpload("file1.txt", clientId, 100)
    let uploadId2 = manager.createUpload("file2.txt", clientId, 200)
    
    # Check session tracking
    let clientSessions = manager.sessionsByClient.getOrDefault(clientId, @[])
    check clientSessions.len == 2
    check uploadId1 in clientSessions
    check uploadId2 in clientSessions
    
    # Test concurrent upload limit
    expect(UploadError):
      discard manager.createUpload("file3.txt", clientId, 300)
    
    # Test statistics
    let stats = manager.getUploadStats()
    check stats.total == 2
    check stats.active == 0  # None started yet
    
    # Clean up one upload
    manager.removeUpload(uploadId1)
    let updatedSessions = manager.sessionsByClient.getOrDefault(clientId, @[])
    check updatedSessions.len == 1
    check uploadId2 in updatedSessions

  test "Upload error conditions and recovery":
    # Test various error conditions and recovery
    var config = defaultUploadConfig()
    config.uploadDir = "test_simple_uploads"
    config.tempDir = "test_simple_uploads/tmp"
    config.maxFileSize = 50  # Very small limit
    
    var manager = newUploadManager(config)
    
    # Test file size limit
    expect(UploadError):
      discard manager.createUpload("large_file.txt", 1, 1000)
    
    # Test invalid upload ID
    let invalidUpload = manager.getUpload("nonexistent")
    check invalidUpload == nil
    
    # Test upload cancellation
    let uploadId = manager.createUpload("cancel_test.txt", 1, 30)
    let upload = manager.getUpload(uploadId)
    check upload != nil
    
    upload[].openForWriting()
    upload[].cancelUpload()
    check upload[].status == UploadCancelled

  test "TUS extensions and metadata handling":
    # Test TUS extensions and metadata
    let config = defaultTUSConfig()
    
    # Test metadata parsing
    let metadataStr = "filename " & base64.encode("test.txt") & ",filetype " & base64.encode("text/plain")
    var headers: HttpHeaders
    headers["Upload-Metadata"] = metadataStr
    
    let tusHeaders = parseTUSHeaders(headers)
    check tusHeaders.uploadMetadata.getOrDefault("filename", "") == "test.txt"
    check tusHeaders.uploadMetadata.getOrDefault("filetype", "") == "text/plain"
    
    # Test TUS response creation with extensions
    let response = createTUSResponse(201, config, "test123", 0, 1024)
    check response.headers["Tus-Extension"].contains("creation")
    check response.headers["Tus-Extension"].contains("checksum")
    check response.headers["Tus-Resumable"] == "1.0.0"

when isMainModule:
  echo "Running simple upload integration tests..."