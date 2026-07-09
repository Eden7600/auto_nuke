defmodule AutoNuke.MixProject do
  use Mix.Project

  def project do
    [
      app: :auto_nuke,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AutoNuke, []}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      {:req, "~> 0.6"},
      {:pid_control, "~> 0.1"},
      {:pubsub, "~> 1.0"},
      {:ex_git_test, "~> 0.1", only: [:dev, :test], runtime: false},
      {:mix_test_watch, "~> 1.4", only: [:dev, :test], runtime: false},
      {:statistex, "~> 1.1"},
      {:memoize, "~> 1.4"},
      {:scholar, "~> 0.4"}
    ]
  end
end
