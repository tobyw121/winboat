package main

import (
	"bytes"
	"encoding/base64"
	"image"
	"image/color"
	"image/png"
	"strings"
	"testing"
)

func TestPNGBounds(t *testing.T) {
	var b bytes.Buffer
	png.Encode(&b, image.NewRGBA(image.Rect(0, 0, 2, 2)))
	if !validClipboardPNG(base64.StdEncoding.EncodeToString(b.Bytes())) {
		t.Fatal("valid PNG rejected")
	}
	for _, s := range []string{"", "not png", base64.StdEncoding.EncodeToString([]byte("bad")), strings.Repeat("a", clipboardImageLimit*2)} {
		if validClipboardPNG(s) {
			t.Fatal("invalid accepted")
		}
	}
}

func TestBitmapRoundtripAndBounds(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	img.Set(0, 0, color.RGBA{R: 255, A: 255})
	var b bytes.Buffer
	png.Encode(&b, img)
	dib, err := clipboardPNGToDIB(b.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	data, err := clipboardDIBToPNG(dib)
	if err != nil || !validClipboardPNG(base64.StdEncoding.EncodeToString(data)) {
		t.Fatal("bitmap roundtrip")
	}
	if _, err = clipboardDIBToPNG(dib[:40]); err == nil {
		t.Fatal("truncated bitmap")
	}
	dib[16] = 1
	if _, err = clipboardDIBToPNG(dib); err == nil {
		t.Fatal("compressed bitmap accepted")
	}
}
