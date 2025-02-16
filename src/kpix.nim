# tpix - a simple terminal image viewer using the kitty graphics protocol
# See https://sw.kovidgoyal.net/kitty/graphics-protocol/ for details

import std / [
  termios,
  terminal,
  math,
  base64,
  strformat,
  strutils
  # strbasics
],
  pixie,
  cligen,
  zippy

# import nimprof
# --profiler:on --stacktrace:on

const NimblePkgVersion {.strdefine.} = "Unknown"
const version = NimblePkgVersion

const
  escStart = "\e_G"
  escEnd = "\e\\"
  chunkSize = 4096

proc terminalWidthPixels(istty: bool): int =
  var winSize: IOctl_WinSize
  if ioctl(cint(not istty), TIOCGWINSZ, addr winsize) != -1:
    result = int(winsize.ws_xpixel)
  else:
    result = 0

proc add(result: var string, a: openArray[char]) =
  result.setLen result.len + a.len
  copyMem result[^a.len].addr, a[0].addr, a.len

proc addChunk(result: var string, ctrlCode: string, imgData: openArray[char]) =
  result.add escStart
  result.add ctrlCode
  result.add imgData
  result.add escEnd

proc resizeImage(img: var Image, termWidth: int, noresize, fullwidth: bool, width, height: int) =
  var
    width = width
    height = height

  if width > 0 and height == 0:
    height = round(img.height.float*(width/img.width)).int
  elif height > 0 and width == 0:
    width = round(img.width.float*(height/img.height)).int
  elif img.width > termWidth and not noresize:
    width = termWidth
    height = round(img.height.float*(termWidth/img.width)).int
  elif fullwidth:
    width = termWidth
    height = round(img.height.float*(termWidth/img.width)).int

  if width != 0:
    img = img.resize(width, height)

proc addBackground(img: var Image) =
  let bgimg = newImage(img.width, img.height)
  bgimg.fill(rgba(255, 255, 255, 255))
  bgimg.draw(img)
  img = bgimg

proc imgDataCompressed(img: Image): string =
  let length = img.width * img.height * 4

  var compressed = compress(img.data[0].addr, length, dataFormat = dfDeflate)
  stderr.write(fmt"{length=} {len compressed=}")
  return encode(compressed)

proc imgData(img: Image): string =
  let length = img.width * img.height * 3
  var pixSeq = newSeq[uint8](length)
  copyMem(pixSeq[0].addr, img.data[0].addr, length)
  return encode(pixSeq)

proc imgDataRGB(img: Image): string =
  let length = img.width * img.height * 3
  var data = newStringOfCap(length)
  for d in img.data:
    data.add(char d.r)
    data.add(char d.g)
    data.add(char d.b)

  return encode(data)

proc renderImage(img: var Image) =
  let
    imgStr = imgDataRGB(img)#encode(imgData(img))#encodeImage(img, PngFormat))
    imgLen = imgStr.len

  var payload = newStringOfCap(imgLen * 2)
  # stderr.write(fmt"{imgLen=} {chunkSize=}")
  if imgLen <= chunkSize:
    var ctrlCode = fmt"a=T,f=24,s={img.width},v={img.height};" #"a=T,f=100;"
    payload.addChunk(ctrlCode, imgStr)
  else:
    var
      ctrlCode = fmt"a=T,f=24,s={img.width},v={img.height},c=50,r=20,m=1;" #"a=T,f=100,m=1;"
      chunk = chunkSize

    while chunk <= imgLen:
      if chunk == imgLen:
        break
      payload.addChunk(ctrlCode, imgStr.toOpenArray(chunk-chunkSize, chunk-1))
      ctrlCode = "m=1;"
      chunk += chunkSize

    ctrlCode = "m=0;"
    payload.addChunk(ctrlCode, imgStr.toOpenArray(chunk-chunkSize, imgLen-1))

  stdout.writeLine(payload)
  # stderr.write("Terminal width in pixels: ", terminalWidthPixels(istty), "\n")

proc processImage(img: var Image, background, noresize, fullwidth: bool,
  termWidth, width, height: int) =

  img.resizeImage(termWidth, noresize, fullwidth, width, height)
  if background:
    img.addBackground
  img.renderImage

proc kpix(
  files: seq[string],
  background = false, printname = false, noresize = false, fullwidth = false,
  width = 0, height = 0) =
  ## A simple terminal image viewer using the kitty graphics protocol

  let
    istty = stdin.isatty
    termWidth = terminalWidthPixels istty

  if not istty:
    if files.len > 0:
      stderr.write("Warning: Input file specified when receiving data from STDIN.\n")
      stderr.write("Only data from STDIN is shown.")
    try:
      if printname:
        echo "Data from STDIN."
      var image = stdin.readAll.decodeImage
      image.processImage(background, noresize, fullwidth, termWidth, width, height)
    except PixieError:
      echo fmt"Error: {getCurrentExceptionMsg()}"
    except AssertionDefect:
      let errMsg = getCurrentExceptionMsg()
      if errMsg.startsWith("gif.nim(173, 16)"):
        echo fmt"Error: Cannot open file. (Possible cause: animated GIFs not supported.)"
    except:
      echo fmt"Error: {getCurrentExceptionMsg()}"
  else:
    if files.len == 0:
      quit("Provide 1 or more files as arguments or pipe image data to STDIN.")
    for filename in files:
      try:
        if printname:
          echo filename
        var image = filename.readImage
        image.processImage(background, noresize, fullwidth, termWidth, width, height)
      except PixieError:
        echo fmt"Error: {getCurrentExceptionMsg()}"
      except AssertionDefect:
        let errMsg = getCurrentExceptionMsg()
        if errMsg.startsWith("gif.nim(173, 16)"):
          echo fmt"Error: Cannot open file. (Possible cause: animated GIFs not supported.)"
      except:
        echo fmt"Error: {getCurrentExceptionMsg()}"

clCfg.version = version
dispatch kpix,
  help = {
    "width": "Specify image width.",
    "height": "Specify image height.",
    "fullwidth": "Resize image to fill terminal width.",
    "noresize": "Disable automatic resizing.",
    "background": "Add white background if image is transparent.",
    "printname": "Print file name."
  }
