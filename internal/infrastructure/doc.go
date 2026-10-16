// Package infrastructure holds the adapters that implement application ports:
// file-backed blob store, write-ahead log, ref store, caches and HTTP clients.
//
// Dependency rule: may import application and domain; must not import api.
package infrastructure
