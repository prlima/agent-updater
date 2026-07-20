// Package security provides cryptographic helpers for webhook verification.
package security

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
)

var (
	ErrMissingSignature = errors.New("X-Hub-Signature-256 header missing")
	ErrInvalidFormat    = errors.New("signature format invalid: expected 'sha256=<hex>'")
	ErrInvalidEncoding  = errors.New("signature hex encoding invalid")
	ErrSignatureMismatch = errors.New("signature mismatch")
)

// VerifyGitHubSignature validates the X-Hub-Signature-256 header against body.
// Uses constant-time comparison to prevent timing attacks.
func VerifyGitHubSignature(secret, body []byte, signatureHeader string) error {
	if signatureHeader == "" {
		return ErrMissingSignature
	}
	if !strings.HasPrefix(signatureHeader, "sha256=") {
		return ErrInvalidFormat
	}

	rawSig, err := hex.DecodeString(strings.TrimPrefix(signatureHeader, "sha256="))
	if err != nil {
		return fmt.Errorf("%w: %v", ErrInvalidEncoding, err)
	}

	mac := hmac.New(sha256.New, secret)
	mac.Write(body) // Write never returns an error for hmac
	expected := mac.Sum(nil)

	// hmac.Equal is constant-time — prevents timing side-channel.
	if !hmac.Equal(rawSig, expected) {
		return ErrSignatureMismatch
	}

	return nil
}
