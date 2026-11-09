package main

import (
	"context"
	"net/http"
)

func withNonce(r *http.Request, n string) context.Context {
	return context.WithValue(r.Context(), nonceKey{}, n)
}

func nonceFrom(r *http.Request) string {
	s, _ := r.Context().Value(nonceKey{}).(string)
	return s
}
