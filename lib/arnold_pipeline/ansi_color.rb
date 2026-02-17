module ArnoldPipeline
  module AnsiColor
    def bold(text)     = "\e[1m#{text}\e[0m"
    def dim(text)      = "\e[2m#{text}\e[0m"
    def red(text)      = "\e[31m#{text}\e[0m"
    def green(text)    = "\e[32m#{text}\e[0m"
    def yellow(text)   = "\e[33m#{text}\e[0m"
    def cyan(text)     = "\e[36m#{text}\e[0m"
    def magenta(text)  = "\e[35m#{text}\e[0m"
    def bg_green(text) = "\e[42;30m#{text}\e[0m"
    def bg_red(text)   = "\e[41;37m#{text}\e[0m"

    def strip_ansi(text)
      text.gsub(/\e\[[0-9;]*m/, "")
    end
  end
end
