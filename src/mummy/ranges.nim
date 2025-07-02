## HTTP Range request support (RFC 7233) for partial uploads and downloads
## Implements Range header parsing and Content-Range response generation

import std/[strutils, strformat, algorithm, random]

type
  RangeError* = object of CatchableError

  RangeUnit* = enum
    ## Supported range units
    RangeBytes = "bytes"

  ByteRange* = object
    ## Represents a single byte range
    start*: int64    ## Start position (inclusive), -1 if not specified
    `end`*: int64    ## End position (inclusive), -1 if not specified

  RangeSpec* = object
    ## Complete range specification from Range header
    unit*: RangeUnit
    ranges*: seq[ByteRange]

  ContentRange* = object
    ## Content-Range header information for responses
    unit*: RangeUnit
    start*: int64        ## Start of range being sent
    `end`*: int64        ## End of range being sent
    totalLength*: int64  ## Total length of resource (-1 if unknown)

proc parseByteRange(rangeStr: string): ByteRange {.raises: [RangeError].} =
  ## Parse a single byte range specification like "0-499" or "500-" or "-200"
  let dashPos = rangeStr.find('-')
  if dashPos == -1:
    raise newException(RangeError, "Invalid range format: missing dash")
  
  let
    startStr = rangeStr[0 ..< dashPos].strip()
    endStr = rangeStr[dashPos + 1 .. ^1].strip()
  
  if startStr.len == 0 and endStr.len == 0:
    raise newException(RangeError, "Invalid range: both start and end empty")
  
  # Parse start position
  if startStr.len == 0:
    result.start = -1  # Suffix range like "-200"
  else:
    try:
      result.start = startStr.parseBiggestInt()
      if result.start < 0:
        raise newException(RangeError, "Range start cannot be negative")
    except ValueError:
      raise newException(RangeError, "Invalid range start: " & startStr)
  
  # Parse end position
  if endStr.len == 0:
    result.`end` = -1  # Open range like "500-"
  else:
    try:
      result.`end` = endStr.parseBiggestInt()
      if result.`end` < 0:
        raise newException(RangeError, "Range end cannot be negative")
    except ValueError:
      raise newException(RangeError, "Invalid range end: " & endStr)
  
  # Validate range logic
  if result.start != -1 and result.`end` != -1 and result.start > result.`end`:
    raise newException(RangeError, "Range start cannot be greater than end")

proc parseRangeHeader*(rangeHeader: string): RangeSpec {.raises: [RangeError].} =
  ## Parse HTTP Range header according to RFC 7233
  ## Format: "bytes=200-1023,2048-2559"
  
  if rangeHeader.len == 0:
    raise newException(RangeError, "Empty range header")
  
  # Find the unit (should be "bytes")
  let eqPos = rangeHeader.find('=')
  if eqPos == -1:
    raise newException(RangeError, "Invalid range header format: missing '='")
  
  let unitStr = rangeHeader[0 ..< eqPos].strip().toLowerAscii()
  if unitStr != "bytes":
    raise newException(RangeError, "Unsupported range unit: " & unitStr)
  
  result.unit = RangeBytes
  
  # Parse range specifications
  let rangesStr = rangeHeader[eqPos + 1 .. ^1].strip()
  if rangesStr.len == 0:
    raise newException(RangeError, "No ranges specified")
  
  let rangeParts = rangesStr.split(',')
  for rangePart in rangeParts:
    let trimmed = rangePart.strip()
    if trimmed.len > 0:
      result.ranges.add(parseByteRange(trimmed))
  
  if result.ranges.len == 0:
    raise newException(RangeError, "No valid ranges found")

proc normalizeRange*(range: ByteRange, contentLength: int64): ByteRange {.raises: [RangeError].} =
  ## Normalize a byte range against actual content length
  ## Handles suffix ranges and open ranges
  
  if contentLength < 0:
    raise newException(RangeError, "Content length cannot be negative")
  
  if contentLength == 0:
    raise newException(RangeError, "Cannot create ranges for empty content")
  
  result = range
  
  # Handle suffix range (e.g., "-200" means last 200 bytes)
  if result.start == -1:
    if result.`end` == -1:
      raise newException(RangeError, "Invalid range: both start and end unspecified")
    result.start = max(0, contentLength - result.`end`)
    result.`end` = contentLength - 1
  else:
    # Handle open range (e.g., "500-" means from 500 to end)
    if result.`end` == -1:
      result.`end` = contentLength - 1
    else:
      # Clamp end to content length
      result.`end` = min(result.`end`, contentLength - 1)
  
  # Validate final range
  if result.start >= contentLength:
    raise newException(RangeError, fmt"Range start {result.start} exceeds content length {contentLength}")
  
  if result.`end` >= contentLength:
    result.`end` = contentLength - 1
  
  if result.start > result.`end`:
    raise newException(RangeError, fmt"Invalid normalized range: {result.start}-{result.`end`}")

proc formatContentRange*(contentRange: ContentRange): string =
  ## Format Content-Range header for HTTP response
  ## Format: "bytes 200-1023/2048" or "bytes */2048" for unsatisfiable range
  
  case contentRange.unit:
  of RangeBytes:
    if contentRange.start == -1 or contentRange.`end` == -1:
      # Unsatisfiable range
      if contentRange.totalLength >= 0:
        result = fmt"bytes */{contentRange.totalLength}"
      else:
        result = "bytes */*"
    else:
      if contentRange.totalLength >= 0:
        result = fmt"bytes {contentRange.start}-{contentRange.`end`}/{contentRange.totalLength}"
      else:
        result = fmt"bytes {contentRange.start}-{contentRange.`end`}/*"

proc isRangeSatisfiable*(range: ByteRange, contentLength: int64): bool =
  ## Check if a byte range can be satisfied given the content length
  try:
    discard normalizeRange(range, contentLength)
    result = true
  except RangeError:
    result = false

proc calculateRangeLength*(range: ByteRange): int64 =
  ## Calculate the number of bytes in a normalized range
  if range.start == -1 or range.`end` == -1:
    return -1  # Cannot calculate for unnormalized ranges
  result = range.`end` - range.start + 1

proc mergeOverlappingRanges*(ranges: seq[ByteRange]): seq[ByteRange] =
  ## Merge overlapping and adjacent byte ranges for efficient processing
  ## Input ranges should be normalized
  
  if ranges.len <= 1:
    return ranges
  
  # Sort ranges by start position
  var sortedRanges = ranges
  sortedRanges.sort do (a, b: ByteRange) -> int:
    if a.start < b.start: -1
    elif a.start > b.start: 1
    else: 0
  
  result = @[sortedRanges[0]]
  
  for i in 1 ..< sortedRanges.len:
    let
      current = sortedRanges[i]
      lastIdx = result.len - 1
    
    # Check if current range overlaps or is adjacent to the last merged range
    if current.start <= result[lastIdx].`end` + 1:
      # Merge ranges by extending the end position
      result[lastIdx].`end` = max(result[lastIdx].`end`, current.`end`)
    else:
      # No overlap, add as new range
      result.add(current)

proc isMultipartRange*(ranges: seq[ByteRange]): bool =
  ## Check if ranges require multipart response
  result = ranges.len > 1

proc generateBoundary*(): string =
  ## Generate a unique boundary string for multipart responses
  randomize()
  result = "mummy_range_" & $rand(1000000000)

proc formatMultipartRangeHeader*(boundary: string, contentType: string, range: ByteRange, totalLength: int64): string =
  ## Format multipart range section header
  result = fmt"""--{boundary}
Content-Type: {contentType}
Content-Range: bytes {range.start}-{range.`end`}/{totalLength}

"""

proc formatMultipartRangeFooter*(boundary: string): string =
  ## Format multipart range closing boundary
  result = fmt"--{boundary}--\r\n"

# Upload-specific range handling

proc parseUploadRange*(contentRangeHeader: string): tuple[start: int64, `end`: int64, total: int64] {.raises: [RangeError].} =
  ## Parse Content-Range header from upload requests
  ## Format: "bytes 200-1023/2048" or "bytes 200-1023/*"
  
  if not contentRangeHeader.startsWith("bytes "):
    raise newException(RangeError, "Content-Range must use bytes unit")
  
  let rangeSpec = contentRangeHeader[6..^1].strip()  # Remove "bytes "
  
  let slashPos = rangeSpec.find('/')
  if slashPos == -1:
    raise newException(RangeError, "Content-Range missing total length")
  
  let
    rangePartStr = rangeSpec[0 ..< slashPos]
    totalStr = rangeSpec[slashPos + 1 .. ^1]
  
  # Parse range part (start-end)
  let dashPos = rangePartStr.find('-')
  if dashPos == -1:
    raise newException(RangeError, "Invalid Content-Range format")
  
  try:
    result.start = rangePartStr[0 ..< dashPos].parseBiggestInt()
    result.`end` = rangePartStr[dashPos + 1 .. ^1].parseBiggestInt()
  except ValueError:
    raise newException(RangeError, "Invalid range values in Content-Range")
  
  # Parse total length
  if totalStr == "*":
    result.total = -1  # Unknown total length
  else:
    try:
      result.total = totalStr.parseBiggestInt()
    except ValueError:
      raise newException(RangeError, "Invalid total length in Content-Range")
  
  # Validate
  if result.start < 0 or result.`end` < 0:
    raise newException(RangeError, "Range values cannot be negative")
  
  if result.start > result.`end`:
    raise newException(RangeError, "Range start cannot be greater than end")
  
  if result.total != -1 and result.`end` >= result.total:
    raise newException(RangeError, "Range end exceeds total length")

proc isRangeComplete*(start: int64, `end`: int64, total: int64): bool =
  ## Check if a range represents a complete upload
  if total <= 0:
    return false
  result = start == 0 and `end` == total - 1

proc getNextExpectedOffset*(currentOffset: int64, rangeStart: int64): bool =
  ## Check if upload range continues from current offset
  result = rangeStart == currentOffset