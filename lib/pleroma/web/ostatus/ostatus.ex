defmodule Pleroma.Web.OStatus do
  @httpoison Application.get_env(:pleroma, :httpoison)

  import Ecto.Query
  import Pleroma.Web.XML
  require Logger

  alias Pleroma.{Repo, User, Web, Object, Activity}
  alias Pleroma.Web.ActivityPub.ActivityPub
  alias Pleroma.Web.{WebFinger, Websub}
  alias Pleroma.Web.OStatus.{FollowHandler, UnfollowHandler, NoteHandler, DeleteHandler}
  alias Pleroma.Web.ActivityPub.Transmogrifier

  def feed_path(user) do
    "#{user.ap_id}/feed.atom"
  end

  def pubsub_path(user) do
    "#{Web.base_url()}/push/hub/#{user.nickname}"
  end

  def salmon_path(user) do
    "#{user.ap_id}/salmon"
  end

  def remote_follow_path do
    "#{Web.base_url()}/ostatus_subscribe?acct={uri}"
  end

  def handle_incoming(xml_string) do
    with doc when doc != :error <- parse_document(xml_string) do
      entries = :xmerl_xpath.string('//entry', doc)

      activities =
        Enum.map(entries, fn entry ->
          {:xmlObj, :string, object_type} =
            :xmerl_xpath.string('string(/entry/activity:object-type[1])', entry)

          {:xmlObj, :string, verb} = :xmerl_xpath.string('string(/entry/activity:verb[1])', entry)
          Logger.debug("Handling #{verb}")

          try do
            case verb do
              'http://activitystrea.ms/schema/1.0/delete' ->
                with {:ok, activity} <- DeleteHandler.handle_delete(entry, doc), do: activity

              'http://activitystrea.ms/schema/1.0/follow' ->
                with {:ok, activity} <- FollowHandler.handle(entry, doc), do: activity

              'http://activitystrea.ms/schema/1.0/unfollow' ->
                with {:ok, activity} <- UnfollowHandler.handle(entry, doc), do: activity

              'http://activitystrea.ms/schema/1.0/share' ->
                with {:ok, activity, retweeted_activity} <- handle_share(entry, doc),
                     do: [activity, retweeted_activity]

              'http://activitystrea.ms/schema/1.0/favorite' ->
                with {:ok, activity, favorited_activity} <- handle_favorite(entry, doc),
                     do: [activity, favorited_activity]

              _ ->
                case object_type do
                  'http://activitystrea.ms/schema/1.0/note' ->
                    with {:ok, activity} <- NoteHandler.handle_note(entry, doc), do: activity

                  'http://activitystrea.ms/schema/1.0/comment' ->
                    with {:ok, activity} <- NoteHandler.handle_note(entry, doc), do: activity

                  _ ->
                    Logger.error("Couldn't parse incoming document")
                    nil
                end
            end
          rescue
            e ->
              Logger.error("Error occured while handling activity")
              Logger.error(xml_string)
              Logger.error(inspect(e))
              nil
          end
        end)
        |> Enum.filter(& &1)

      {:ok, activities}
    else
      _e -> {:error, []}
    end
  end

  def make_share(entry, doc, retweeted_activity) do
    with {:ok, actor} <- find_make_or_update_user(doc),
         %Object{} = object <- Object.normalize(retweeted_activity.data["object"]),
         id when not is_nil(id) <- string_from_xpath("/entry/id", entry),
         {:ok, activity, _object} = ActivityPub.announce(actor, object, id, false) do
      {:ok, activity}
    end
  end

  def handle_share(entry, doc) do
    with {:ok, retweeted_activity} <- get_or_build_object(entry),
         {:ok, activity} <- make_share(entry, doc, retweeted_activity) do
      {:ok, activity, retweeted_activity}
    else
      e -> {:error, e}
    end
  end

  def make_favorite(entry, doc, favorited_activity) do
    with {:ok, actor} <- find_make_or_update_user(doc),
         %Object{} = object <- Object.normalize(favorited_activity.data["object"]),
         id when not is_nil(id) <- string_from_xpath("/entry/id", entry),
         {:ok, activity, _object} = ActivityPub.like(actor, object, id, false) do
      {:ok, activity}
    end
  end

  def get_or_build_object(entry) do
    with {:ok, activity} <- get_or_try_fetching(entry) do
      {:ok, activity}
    else
      _e ->
        with [object] <- :xmerl_xpath.string('/entry/activity:object', entry) do
          NoteHandler.handle_note(object, object)
        end
    end
  end

  def get_or_try_fetching(entry) do
    Logger.debug("Trying to get entry from db")

    with id when not is_nil(id) <- string_from_xpath("//activity:object[1]/id", entry),
         %Activity{} = activity <- Activity.get_create_activity_by_object_ap_id(id) do
      {:ok, activity}
    else
      _ ->
        Logger.debug("Couldn't get, will try to fetch")

        with href when not is_nil(href) <-
               string_from_xpath("//activity:object[1]/link[@type=\"text/html\"]/@href", entry),
             {:ok, [favorited_activity]} <- fetch_activity_from_url(href) do
          {:ok, favorited_activity}
        else
          e -> Logger.debug("Couldn't find href: #{inspect(e)}")
        end
    end
  end

  def handle_favorite(entry, doc) do
    with {:ok, favorited_activity} <- get_or_try_fetching(entry),
         {:ok, activity} <- make_favorite(entry, doc, favorited_activity) do
      {:ok, activity, favorited_activity}
    else
      e -> {:error, e}
    end
  end

  def get_attachments(entry) do
    :xmerl_xpath.string('/entry/link[@rel="enclosure"]', entry)
    |> Enum.map(fn enclosure ->
      with href when not is_nil(href) <- string_from_xpath("/link/@href", enclosure),
           type when not is_nil(type) <- string_from_xpath("/link/@type", enclosure) do
        %{
          "type" => "Attachment",
          "url" => [
            %{
              "type" => "Link",
              "mediaType" => type,
              "href" => href
            }
          ]
        }
      end
    end)
    |> Enum.filter(& &1)
  end

  @doc """
    Gets the content from a an entry.
  """
  def get_content(entry) do
    string_from_xpath("//content", entry)
  end

  @doc """
    Get the cw that mastodon uses.
  """
  def get_cw(entry) do
    with cw when not is_nil(cw) <- string_from_xpath("/*/summary", entry) do
      cw
    else
      _e -> nil
    end
  end

  def get_tags(entry) do
    :xmerl_xpath.string('//category', entry)
    |> Enum.map(fn category -> string_from_xpath("/category/@term", category) end)
    |> Enum.filter(& &1)
    |> Enum.map(&String.downcase/1)
  end

  def maybe_update(doc, user) do
    if "true" == string_from_xpath("//author[1]/ap_enabled", doc) do
      Transmogrifier.upgrade_user_from_ap_id(user.ap_id)
    else
      maybe_update_ostatus(doc, user)
    end
  end

  def maybe_update_ostatus(doc, user) do
    old_data = %{
      avatar: user.avatar,
      bio: user.bio,
      name: user.name,
      info: user.info
    }

    with false <- user.local,
         avatar <- make_avatar_object(doc),
         bio <- string_from_xpath("//author[1]/summary", doc),
         name <- string_from_xpath("//author[1]/poco:displayName", doc),
         info <-
           Map.put(user.info, "banner", make_avatar_object(doc, "header") || user.info["banner"]),
         new_data <- %{
           avatar: avatar || old_data.avatar,
           name: name || old_data.name,
           bio: bio || old_data.bio,
           info: info || old_data.info
         },
         false <- new_data == old_data do
      change = Ecto.Changeset.change(user, new_data)
      Repo.update(change)
    else
      _ ->
        {:ok, user}
    end
  end

  def find_make_or_update_user(doc) do
    uri = string_from_xpath("//author/uri[1]", doc)

    with {:ok, user} <- find_or_make_user(uri) do
      maybe_update(doc, user)
    end
  end

  def find_or_make_user(uri) do
    query = from(user in User, where: user.ap_id == ^uri)

    user = Repo.one(query)

    if is_nil(user) do
      make_user(uri)
    else
      {:ok, user}
    end
  end

  def make_user(uri, update \\ false) do
    with {:ok, info} <- gather_user_info(uri) do
      data = %{
        name: info["name"],
        nickname: info["nickname"] <> "@" <> info["host"],
        ap_id: info["uri"],
        info: info,
        avatar: info["avatar"],
        bio: info["bio"]
      }

      with false <- update,
           %User{} = user <- User.get_by_ap_id(data.ap_id) do
        {:ok, user}
      else
        _e -> User.insert_or_update_user(data)
      end
    end
  end

  # TODO: Just takes the first one for now.
  def make_avatar_object(author_doc, rel \\ "avatar") do
    href = string_from_xpath("//author[1]/link[@rel=\"#{rel}\"]/@href", author_doc)
    type = string_from_xpath("//author[1]/link[@rel=\"#{rel}\"]/@type", author_doc)

    if href do
      %{
        "type" => "Image",
        "url" => [
          %{
            "type" => "Link",
            "mediaType" => type,
            "href" => href
          }
        ]
      }
    else
      nil
    end
  end

  def gather_user_info(username) do
    with {:ok, webfinger_data} <- WebFinger.finger(username),
         {:ok, feed_data} <- Websub.gather_feed_data(webfinger_data["topic"]) do
      user_data = Map.merge(webfinger_data, feed_data)
      username_starts_with_acct = String.starts_with?(username, "acct")

      fqn =
        if username_starts_with_acct do
          gather_user_fqn(user_data, username)
        else
          username
        end

      {:ok, user_data |> Map.put("fqn", fqn)}
    else
      e ->
        Logger.debug(fn -> "Couldn't gather info for #{username}" end)
        {:error, e}
    end
  end

  def gather_user_fqn(user_data, username) do
    gather_user_fqn(user_data, username, [])
  end

  def gather_user_fqn(user_data, username, old_usernames) do
    starts_with_acct = String.starts_with?(user_data["subject"], "acct")

    if starts_with_acct && user_data["subject"] != username &&
         (old_usernames == [] || !old_usernames.contains(user_data["subject"])) do
      with ["acct", fqn] <- String.split(user_data["subject"], ":", 2),
           {:ok, webfinger_data} <- WebFinger.finger(username),
           {:ok, feed_data} <- Websub.gather_feed_data(webfinger_data["topic"]) do
        fqn_user_data = Map.merge(webfinger_data, feed_data)
        gather_user_fqn(fqn_user_data, fqn, old_usernames ++ [username])
      else
        _e -> username
      end
    else
      username
    end
  end

  # Regex-based 'parsing' so we don't have to pull in a full html parser
  # It's a hack anyway. Maybe revisit this in the future
  @mastodon_regex ~r/<link href='(.*)' rel='alternate' type='application\/atom\+xml'>/
  @gs_regex ~r/<link title=.* href="(.*)" type="application\/atom\+xml" rel="alternate">/
  @gs_classic_regex ~r/<link rel="alternate" href="(.*)" type="application\/atom\+xml" title=.*>/
  def get_atom_url(body) do
    cond do
      Regex.match?(@mastodon_regex, body) ->
        [[_, match]] = Regex.scan(@mastodon_regex, body)
        {:ok, match}

      Regex.match?(@gs_regex, body) ->
        [[_, match]] = Regex.scan(@gs_regex, body)
        {:ok, match}

      Regex.match?(@gs_classic_regex, body) ->
        [[_, match]] = Regex.scan(@gs_classic_regex, body)
        {:ok, match}

      true ->
        Logger.debug(fn -> "Couldn't find Atom link in #{inspect(body)}" end)
        {:error, "Couldn't find the Atom link"}
    end
  end

  def fetch_activity_from_atom_url(url) do
    with true <- String.starts_with?(url, "http"),
         {:ok, %{body: body, status_code: code}} when code in 200..299 <-
           @httpoison.get(
             url,
             [Accept: "application/atom+xml"],
             follow_redirect: true,
             timeout: 10000,
             recv_timeout: 20000
           ) do
      Logger.debug("Got document from #{url}, handling...")
      handle_incoming(body)
    else
      e ->
        Logger.debug("Couldn't get #{url}: #{inspect(e)}")
        e
    end
  end

  def fetch_activity_from_html_url(url) do
    Logger.debug("Trying to fetch #{url}")

    with true <- String.starts_with?(url, "http"),
         {:ok, %{body: body}} <-
           @httpoison.get(url, [], follow_redirect: true, timeout: 10000, recv_timeout: 20000),
         {:ok, atom_url} <- get_atom_url(body) do
      fetch_activity_from_atom_url(atom_url)
    else
      e ->
        Logger.debug("Couldn't get #{url}: #{inspect(e)}")
        e
    end
  end

  def fetch_activity_from_url(url) do
    try do
      with {:ok, activities} when length(activities) > 0 <- fetch_activity_from_atom_url(url) do
        {:ok, activities}
      else
        _e ->
          with {:ok, activities} <- fetch_activity_from_html_url(url) do
            {:ok, activities}
          end
      end
    rescue
      e ->
        Logger.debug("Couldn't get #{url}: #{inspect(e)}")
        {:error, "Couldn't get #{url}: #{inspect(e)}"}
    end
  end
end
