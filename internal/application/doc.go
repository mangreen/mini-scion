// Package application holds the use cases and the ports (interfaces) they
// need, such as BlobStore and RefStore. It orchestrates the domain and never
// touches files, sockets or the network directly.
//
// Dependency rule: may import domain; must not import infrastructure or api.
package application
