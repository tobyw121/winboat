package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"image"
	"image/color"
	"image/png"
)

// Only bounded uncompressed 24/32-bit Windows DIBs; no palettes, RLE or bitfields.
func clipboardDIBToPNG(data []byte) ([]byte, error) {
	if len(data) < 40 {
		return nil, fmt.Errorf("short bitmap")
	}
	header := int(binary.LittleEndian.Uint32(data))
	w := int(int32(binary.LittleEndian.Uint32(data[4:])))
	height := int(int32(binary.LittleEndian.Uint32(data[8:])))
	if header != 40 && header != 108 && header != 124 {
		return nil, fmt.Errorf("unsupported bitmap header")
	}
	top := height < 0
	if top {
		height = -height
	}
	bpp := int(binary.LittleEndian.Uint16(data[14:]))
	compression := binary.LittleEndian.Uint32(data[16:])
	if w <= 0 || height <= 0 || w > 4096 || height > 4096 || w*height > 8*1024*1024 || binary.LittleEndian.Uint16(data[12:]) != 1 || (bpp != 24 && bpp != 32) || compression != 0 {
		return nil, fmt.Errorf("unsupported bitmap layout")
	}
	stride := (w*bpp + 31) / 32 * 4
	if header > len(data) || stride*height > len(data)-header {
		return nil, fmt.Errorf("truncated bitmap")
	}
	img := image.NewNRGBA(image.Rect(0, 0, w, height))
	for y := 0; y < height; y++ {
		sourceY := height - 1 - y
		if top {
			sourceY = y
		}
		for x := 0; x < w; x++ {
			off := header + sourceY*stride + x*(bpp/8)
			img.SetNRGBA(x, y, color.NRGBA{R: data[off+2], G: data[off+1], B: data[off], A: 255})
		}
	}
	var out bytes.Buffer
	if err := png.Encode(&out, img); err != nil {
		return nil, err
	}
	if out.Len() > clipboardImageLimit {
		return nil, fmt.Errorf("encoded PNG too large")
	}
	return out.Bytes(), nil
}
func clipboardPNGToDIB(data []byte) ([]byte, error) {
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width <= 0 || config.Height <= 0 || config.Width > 4096 || config.Height > 4096 || config.Width*config.Height > 8*1024*1024 {
		return nil, fmt.Errorf("invalid PNG extent")
	}
	img, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	w, h := config.Width, config.Height
	out := make([]byte, 40+w*h*4)
	binary.LittleEndian.PutUint32(out, 40)
	binary.LittleEndian.PutUint32(out[4:], uint32(w))
	binary.LittleEndian.PutUint32(out[8:], uint32(h))
	binary.LittleEndian.PutUint16(out[12:], 1)
	binary.LittleEndian.PutUint16(out[14:], 32)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := color.NRGBAModel.Convert(img.At(x, y)).(color.NRGBA)
			off := 40 + ((h-1-y)*w+x)*4
			out[off] = c.B
			out[off+1] = c.G
			out[off+2] = c.R
			out[off+3] = c.A
		}
	}
	return out, nil
}
