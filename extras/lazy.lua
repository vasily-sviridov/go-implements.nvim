return {
  {
    name = "go-implements.nvim",
    dir = vim.fn.stdpath("config") .. "/local/go-implements.nvim",
    main = "go-implements",
    ft = "go",
    cmd = "GoImplementsRefresh",
    opts = {},
  },
}
