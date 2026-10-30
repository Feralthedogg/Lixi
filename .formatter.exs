[
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "examples/plugins/*/lib/**/*.ex"
  ],
  excludes: ["test/{runtime,tmp}/**/*.{ex,exs}"]
]
