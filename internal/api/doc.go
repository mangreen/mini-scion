// Package api holds the HTTP handlers, request validation and middleware.
// It translates HTTP into use case calls and back.
//
// Dependency rule: may import application and domain; must not import
// infrastructure directly (wiring happens in cmd/).
package api
