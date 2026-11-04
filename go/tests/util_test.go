package tests

import (
	"strconv"
	"strings"
)

func strconvI(n int) string { return strconv.Itoa(n) }

func strconvI64(n int64) string { return strconv.FormatInt(n, 10) }

func splitLines(s string) []string { return strings.Split(s, "\n") }
