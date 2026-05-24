defmodule Symphony1.Service.Launchd do
  @moduledoc """
  Pure plist generator for macOS launchd service packaging.

  Takes an explicit config map and produces plist XML content.
  No file IO, no env lookups, no launchctl calls.
  """

  @label "com.symphony1.operate"
  @launch_agents_dir Path.expand("~/Library/LaunchAgents")

  def label, do: @label
  def plist_path, do: Path.join(@launch_agents_dir, "#{@label}.plist")
  def stdout_log(base \\ File.cwd!()), do: Path.join(base, "log/operate.stdout.log")
  def stderr_log(base \\ File.cwd!()), do: Path.join(base, "log/operate.stderr.log")
  def repo_local_plist(base \\ File.cwd!()), do: Path.join(base, "tmp/service/#{@label}.plist")

  @doc """
  Extracts key service config from plist XML content.
  Returns a map with graph_path, team_key, stdout_log, stderr_log.
  """
  @spec parse_plist(String.t()) :: map()
  def parse_plist(content) do
    %{
      graph_path: extract_xml_value(content, "--graph"),
      team_key: extract_xml_value(content, "--team-key"),
      stdout_log: extract_xml_key_value(content, "StandardOutPath"),
      stderr_log: extract_xml_key_value(content, "StandardErrorPath")
    }
  end

  defp extract_xml_value(content, flag) do
    case Regex.run(~r/<string>#{Regex.escape(flag)}<\/string>\s*<string>([^<]+)<\/string>/, content) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp extract_xml_key_value(content, key) do
    case Regex.run(~r/<key>#{Regex.escape(key)}<\/key>\s*<string>([^<]+)<\/string>/, content) do
      [_, value] -> value
      _ -> nil
    end
  end

  @spec generate_plist(map()) :: String.t()
  def generate_plist(config) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{xml_escape(config.label)}</string>

      <key>ProgramArguments</key>
      <array>
        <string>#{xml_escape(config.mix_path)}</string>
        <string>symphony.operate</string>
        <string>--graph</string>
        <string>#{xml_escape(config.graph_path)}</string>
        <string>--team-key</string>
        <string>#{xml_escape(config.team_key)}</string>
      </array>

      <key>WorkingDirectory</key>
      <string>#{xml_escape(config.working_directory)}</string>

      <key>StandardOutPath</key>
      <string>#{xml_escape(config.stdout_log)}</string>

      <key>StandardErrorPath</key>
      <string>#{xml_escape(config.stderr_log)}</string>

    #{render_env(config.env)}
      <key>RunAtLoad</key>
      <true/>

      <key>KeepAlive</key>
      <true/>
    </dict>
    </plist>
    """
    |> String.trim()
  end

  defp render_env(env) when map_size(env) == 0, do: ""

  defp render_env(env) do
    entries =
      env
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map(fn {key, value} ->
        "      <key>#{xml_escape(key)}</key>\n      <string>#{xml_escape(value)}</string>"
      end)
      |> Enum.join("\n")

    """
      <key>EnvironmentVariables</key>
      <dict>
    #{entries}
      </dict>

    """
  end

  defp xml_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
