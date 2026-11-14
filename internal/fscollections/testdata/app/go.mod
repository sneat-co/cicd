module example.com/app

go 1.26

require (
	github.com/dal-go/dalgo v0.0.0
	github.com/dal-go/record v0.0.0
)

replace (
	github.com/dal-go/dalgo => ../dalgo
	github.com/dal-go/record => ../record
)
