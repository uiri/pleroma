defmodule Pleroma.Web.WebFinger do
  @compile if Mix.env() == :test, do: :export_all
  @httpoison Application.get_env(:pleroma, :httpoison)

  alias Pleroma.{User, XmlBuilder}
  alias Pleroma.Web
  alias Pleroma.Web.{XML, Salmon, OStatus}
  require Jason
  require Logger

  def host_meta do
    base_url = Web.base_url()

    {
      :XRD,
      %{xmlns: "http://docs.oasis-open.org/ns/xri/xrd-1.0"},
      {
        :Link,
        %{
          rel: "lrdd",
          type: "application/xrd+xml",
          template: "#{base_url}/.well-known/webfinger?resource={uri}"
        }
      }
    }
    |> XmlBuilder.to_doc()
  end

  def webfinger(resource, fmt) when fmt in ["XML", "JSON"] do
    domain = Application.get_env(:pleroma, Pleroma.Web.Endpoint)[:domain]
    host = Pleroma.Web.Endpoint.host()

    regex =
      if domain do
        ~r/(acct:)?(?<username>\w+)@(#{host}|#{domain})/
      else
        ~r/(acct:)?(?<username>\w+)@#{host}/
      end

    with %{"username" => username} <- Regex.named_captures(regex, resource),
         %User{} = user <- User.get_by_nickname(username) do
      {:ok, represent_user(user, fmt)}
    else
      _e ->
        with %User{} = user <- User.get_cached_by_ap_id(resource) do
          {:ok, represent_user(user, fmt)}
        else
          _e ->
            {:error, "Couldn't find user"}
        end
    end
  end

  def represent_user(user, "JSON") do
    {:ok, user} = ensure_keys_present(user)
    {:ok, _private, public} = Salmon.keys_from_pem(user.info["keys"])
    magic_key = Salmon.encode_key(public)

    host =
      if Application.get_env(:pleroma, Pleroma.Web.Endpoint)[:domain] do
        Application.get_env(:pleroma, Pleroma.Web.Endpoint)[:domain]
      else
        Pleroma.Web.Endpoint.host()
      end

    %{
      "subject" => "acct:#{user.nickname}@#{host}",
      "aliases" => [user.ap_id],
      "links" => [
        %{
          "rel" => "http://schemas.google.com/g/2010#updates-from",
          "type" => "application/atom+xml",
          "href" => OStatus.feed_path(user)
        },
        %{
          "rel" => "http://webfinger.net/rel/profile-page",
          "type" => "text/html",
          "href" => user.ap_id
        },
        %{"rel" => "salmon", "href" => OStatus.salmon_path(user)},
        %{
          "rel" => "magic-public-key",
          "href" => "data:application/magic-public-key,#{magic_key}"
        },
        %{"rel" => "self", "type" => "application/activity+json", "href" => user.ap_id},
        %{
          "rel" => "self",
          "type" => "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"",
          "href" => user.ap_id
        },
        %{
          "rel" => "http://ostatus.org/schema/1.0/subscribe",
          "template" => OStatus.remote_follow_path()
        }
      ]
    }
  end

  def represent_user(user, "XML") do
    {:ok, user} = ensure_keys_present(user)
    {:ok, _private, public} = Salmon.keys_from_pem(user.info["keys"])
    magic_key = Salmon.encode_key(public)

    host =
      if Application.get_env(:pleroma, Pleroma.Web.Endpoint)[:domain] do
        Application.get_env(:pleroma, Pleroma.Web.Endpoint)[:domain]
      else
        Pleroma.Web.Endpoint.host()
      end

    {
      :XRD,
      %{xmlns: "http://docs.oasis-open.org/ns/xri/xrd-1.0"},
      [
        {:Subject, "acct:#{user.nickname}@#{host}"},
        {:Alias, user.ap_id},
        {:Link,
         %{
           rel: "http://schemas.google.com/g/2010#updates-from",
           type: "application/atom+xml",
           href: OStatus.feed_path(user)
         }},
        {:Link,
         %{rel: "http://webfinger.net/rel/profile-page", type: "text/html", href: user.ap_id}},
        {:Link, %{rel: "salmon", href: OStatus.salmon_path(user)}},
        {:Link,
         %{rel: "magic-public-key", href: "data:application/magic-public-key,#{magic_key}"}},
        {:Link, %{rel: "self", type: "application/activity+json", href: user.ap_id}},
        {:Link,
         %{rel: "http://ostatus.org/schema/1.0/subscribe", template: OStatus.remote_follow_path()}}
      ]
    }
    |> XmlBuilder.to_doc()
  end

  # This seems a better fit in Salmon
  def ensure_keys_present(user) do
    info = user.info || %{}

    if info["keys"] do
      {:ok, user}
    else
      {:ok, pem} = Salmon.generate_rsa_pem()
      info = Map.put(info, "keys", pem)

      Ecto.Changeset.change(user, info: info)
      |> User.update_and_set_cache()
    end
  end

  defp get_magic_key(magic_key) do
    "data:application/magic-public-key," <> magic_key = magic_key
    {:ok, magic_key}
  rescue
    MatchError -> {:error, "Missing magic key data."}
  end

  defp webfinger_from_xml(doc) do
    with magic_key <- XML.string_from_xpath(~s{//Link[@rel="magic-public-key"]/@href}, doc),
         {:ok, magic_key} <- get_magic_key(magic_key),
         topic <-
           XML.string_from_xpath(
             ~s{//Link[@rel="http://schemas.google.com/g/2010#updates-from"]/@href},
             doc
           ),
         subject <- XML.string_from_xpath("//Subject", doc),
         salmon <- XML.string_from_xpath(~s{//Link[@rel="salmon"]/@href}, doc),
         subscribe_address <-
           XML.string_from_xpath(
             ~s{//Link[@rel="http://ostatus.org/schema/1.0/subscribe"]/@template},
             doc
           ),
         ap_id <-
           XML.string_from_xpath(
             ~s{//Link[@rel="self" and @type="application/activity+json"]/@href},
             doc
           ) do
      data = %{
        "magic_key" => magic_key,
        "topic" => topic,
        "subject" => subject,
        "salmon" => salmon,
        "subscribe_address" => subscribe_address,
        "ap_id" => ap_id
      }

      {:ok, data}
    else
      {:error, e} ->
        {:error, e}

      e ->
        {:error, e}
    end
  end

  defp webfinger_from_json(doc) do
    data =
      Enum.reduce(doc["links"], %{"subject" => doc["subject"]}, fn link, data ->
        case {link["type"], link["rel"]} do
          {"application/activity+json", "self"} ->
            Map.put(data, "ap_id", link["href"])

          {"application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"", "self"} ->
            Map.put(data, "ap_id", link["href"])

          {_, "magic-public-key"} ->
            "data:application/magic-public-key," <> magic_key = link["href"]
            Map.put(data, "magic_key", magic_key)

          {"application/atom+xml", "http://schemas.google.com/g/2010#updates-from"} ->
            Map.put(data, "topic", link["href"])

          {_, "salmon"} ->
            Map.put(data, "salmon", link["href"])

          {_, "http://ostatus.org/schema/1.0/subscribe"} ->
            Map.put(data, "subscribe_address", link["template"])

          _ ->
            Logger.debug("Unhandled type: #{inspect(link["type"])}")
            data
        end
      end)

    {:ok, data}
  end

  def get_template_from_xml(body) do
    xpath = "//Link[@rel='lrdd']/@template"

    with doc when doc != :error <- XML.parse_document(body),
         template when template != nil <- XML.string_from_xpath(xpath, doc) do
      {:ok, template}
    end
  end

  def find_lrdd_template(domain) do
    with {:ok, %{status_code: status_code, body: body}} when status_code in 200..299 <-
           @httpoison.get("http://#{domain}/.well-known/host-meta", [], follow_redirect: true) do
      get_template_from_xml(body)
    else
      _ ->
        with {:ok, %{body: body}} <- @httpoison.get("https://#{domain}/.well-known/host-meta", []) do
          get_template_from_xml(body)
        else
          e -> {:error, "Can't find LRDD template: #{inspect(e)}"}
        end
    end
  end

  def finger(account) do
    account = String.trim_leading(account, "@")

    domain =
      with [_name, domain] <- String.split(account, "@") do
        domain
      else
        _e ->
          URI.parse(account).host
      end

    address =
      case find_lrdd_template(domain) do
        {:ok, template} ->
          String.replace(template, "{uri}", URI.encode(account))

        _ ->
          "https://#{domain}/.well-known/webfinger?resource=acct:#{account}"
      end

    with response <-
           @httpoison.get(
             address,
             [Accept: "application/xrd+xml,application/jrd+json"],
             follow_redirect: true
           ),
         {:ok, %{status_code: status_code, body: body}} when status_code in 200..299 <- response do
      doc = XML.parse_document(body)

      if doc != :error do
        webfinger_from_xml(doc)
      else
        with {:ok, doc} <- Jason.decode(body) do
          webfinger_from_json(doc)
        else
          {:error, e} -> e
        end
      end
    else
      e ->
        Logger.debug(fn -> "Couldn't finger #{account}" end)
        Logger.debug(fn -> inspect(e) end)
        {:error, e}
    end
  end
end
