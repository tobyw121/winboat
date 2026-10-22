package main

import (
	"bytes"
	"encoding/base64"
	"image/png"
)

const clipboardImageLimit = 8 * 1024 * 1024

func validClipboardPNG(value string) bool {
	if len(value) > ((clipboardImageLimit+2)/3)*4 || value == "" {
		return false
	}
	data, err := base64.StdEncoding.Strict().DecodeString(value)
	if err != nil || len(data) > clipboardImageLimit {
		return false
	}
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width <= 0 || config.Height <= 0 || config.Width > 4096 || config.Height > 4096 || config.Width*config.Height > 8*1024*1024 {
		return false
	}
	_, err = png.Decode(bytes.NewReader(data))
	return err == nil
}
