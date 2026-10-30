[
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "scripts/{ci,validation}/*.exs",
    "examples/plugins/*/lib/**/*.ex"
  ],
  excludes: ["test/{runtime,tmp}/**/*.{ex,exs}"]
]
