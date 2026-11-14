module example.com/app

go 1.26

require (
	example.com/depmod v0.0.0
	github.com/dal-go/dalgo v0.0.0
	github.com/dal-go/record v0.0.0
	github.com/sneat-co/sneat-go-core v0.0.0
)

replace (
	example.com/depmod => ../depmod
	github.com/dal-go/dalgo => ../dalgo
	github.com/dal-go/record => ../record
	github.com/sneat-co/sneat-go-core => ../coretypes
)
