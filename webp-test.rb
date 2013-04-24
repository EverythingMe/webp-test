#!/usr/bin/env ruby
#
# Compare WebP and JPEG compression of images.
#
# Copyright 2013 DoAT. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY DoAT ``AS IS'' AND ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
# EVENT SHALL DoAT OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
# OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# The views and conclusions contained in the software and documentation are
# those of the authors and should not be interpreted as representing official
# policies, either expressed or implied, of DoAT



# This script can be used to study the size improvements offered by using
# WebP and/or JPEG-XR formats instead of PNG.
#
# To use this script, you need to have the following tools in your
# path:
#   * cjpeg, djpeg from libjpeg, available at http://www.ijg.org
#   * cwepb, dwepb from libwebp, available at http://developers.google.com/speed/webp/
#   * convert from ImageMagick, available at http://www.imagemagick.org/
#   * dssim, available at https://github.com/pornel/dssim
#
# After you have gathered all the necessary tools, edit the following section
# to the specific of your test, and then run this script as follows:
# 
#   ruby webp-test.rb output-file pngfile1 pngfile2 pngfile3 ...
#
# where output-file is the name of the file to create the output in (using tab
# seperated columns), followed by the name of the files you'd like to test.
#


OUT_DIR = '/tmp/webp-tests/' # Directory to store temporary files in
USE_LIBJPEG = true           # Whether to use cjpeg & djpeg or convert to
                             # convert from and to JPEG
DELETE_FILES = true          # If true, delete the temporary files
                             # created during tests

############################################################################

## Returns the DSSIM of the given PNGs, nil if failed
def get_dssim(src_png, dst_png)
  dssim_str = `dssim #{src_png} #{dst_png}`
  Float(dssim_str) rescue nil
end

def png_basename(filename)
  File.basename filename, '.png'
end


## Takes a PNG file, compresses to WebP, calculates the DSSIM index
## between the source and compressed files.
## Returns the size of the WebP file, and the DSSIM index.
def webp_size_dssim(src_png, basename = nil)
  basename ||= png_basename src_png
  
  webp_file = File.join OUT_DIR, "#{basename}.webp"
  `cwebp -quiet #{src_png} -o #{webp_file}`
  return nil unless File.exist? webp_file

  size = File.stat(webp_file).size
  
  dwebp_file = File.join OUT_DIR, "#{basename}-dwebp.png"
  `dwebp #{webp_file} -o #{dwebp_file}`
  File.delete webp_file if DELETE_FILES
  return nil unless File.exist? dwebp_file

  dssim = get_dssim(src_png, dwebp_file)

  File.delete dwebp_file if DELETE_FILES
  
  [size, dssim]
end

## Take a PNG file, strips the alpha, compresses to JPEG, calculate the
## DSSIM index between the source and compressed files.
## Returns the size of the JPEG file, and the DSSIM index.
def jpeg_size_dssim(src_png, quality, basename = nil)
  basename ||= png_basename src_png

  # Strip the alpha to level the playing field.
  flat_file = File.join OUT_DIR, "#{basename}-flat.png"
  `convert #{src_png} -background black -flatten +matte #{flat_file}`
  return nil unless File.exist? flat_file

  jpeg_file = File.join OUT_DIR, "#{basename}.jpg"

  if USE_LIBJPEG
    # cjpeg expects PPM.
    # Flat PNG -> PPM:
    ppm_file = File.join OUT_DIR, "#{basename}.ppm"
    `convert #{flat_file} #{ppm_file}`

    # PPM -> PNG:
    `cjpeg -optimize -quality #{quality} -outfile #{jpeg_file} #{ppm_file}`
    File.delete ppm_file if DELETE_FILES
  else
    `convert #{flat_file} -quality #{quality} #{jpeg_file}`
  end

  return nil unless File.exist? jpeg_file

  size = File.stat(jpeg_file).size

  if USE_LIBJPEG
    # JPG -> PPM:
    djpeg_ppm_file = File.join OUT_DIR, "#{basename}-djpeg.ppm"
    `djpeg -outfile #{djpeg_ppm_file} #{jpeg_file}`
    File.delete jpeg_file if DELETE_FILES
    return nil unless File.exist? djpeg_ppm_file
  else
    djpeg_ppm_file = jpeg_file
  end
  
  # PPM -> PNG: 
  djpeg_file = File.join OUT_DIR, "#{basename}-djpeg.png"
  `convert #{djpeg_ppm_file} #{djpeg_file}`
  File.delete djpeg_ppm_file if DELETE_FILES
  return nil unless File.exist? djpeg_file
  
  dssim = get_dssim(flat_file, djpeg_file)

  File.delete djpeg_file, flat_file if DELETE_FILES
  
  [size, dssim]
end


## Try and make a file with a similar DSSIM to the given, based
## on a quality given to the conversion routine.
## Returns size of the file, DSSIM index, and quality used.
def jpeg_bsearch_dssim(src_png, target_dssim, basename = nil)
  basename ||= png_basename src_png

  # Found 90 to be a good place to start.
  q_start, q_end = 80, 100

  while q_end > q_start+1
    quality = (q_start + q_end) / 2
    size, dssim = jpeg_size_dssim src_png, quality, basename
    return nil unless dssim

    delta = dssim - target_dssim

    break if delta.abs < 0.01
    
    if delta > 0
      q_start = quality
    else
      q_end = quality
    end
  end

  [size, dssim, quality]
end

## Takes a PNG file, compressed it to WebP and measures the DSSIM index,
## then compress it to JPEG with a similar DSSIM index, and measures the
## DSSIM index for that.
## Returns the WebP size and DSSIM index, JPEG size and DSSIM index.
def test_file(src_png)
  basename ||= png_basename src_png

  res = [File.stat(src_png).size]
  
  webp_size, webp_dssim = webp_size_dssim( src_png, basename )
  return nil if !(webp_size && webp_dssim)
  res << webp_size << webp_dssim
  
  res += jpeg_bsearch_dssim( src_png, webp_dssim, basename )
  return nil if res.index nil

  res
end  

def main(output_file, files)
  abort "#{OUT_DIR} doesn't exists. mkdir before running" \
    unless Dir.exist? OUT_DIR

  output = File.open(output_file, 'w')
  output.puts "#File\tPNG-Size\tWebP-Size\tWebP-DSSIM\tJPEG-Size\tJPEG-DSSIM\tJPEG-Quality"
     
  files.each do |file|
    abort "Can't find #{file}" unless File.exist? file
      res = test_file file
      if !res || res.index(nil)
        puts "Error in file #{file}, skipping"
      else
        output.puts( "#{file}\t#{res.flatten.join "\t"}" ) unless res.index nil
      end
  end

  output.close
end

abort "Usage: webp-tests output-file png-file [...]" unless ARGV.length > 1
main ARGV.shift, ARGV




