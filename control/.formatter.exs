[
  import_deps: [
    :ecto,
    :ecto_sql,
    :phoenix,
    :spark,
    :ash,
    :ash_postgres,
    :ash_state_machine,
    :reactor,
    :ash_oban,
    :ash_phoenix
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
