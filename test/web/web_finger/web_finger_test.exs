defmodule Pleroma.Web.WebFingerTest do
  use Pleroma.DataCase
  alias Pleroma.Web.WebFinger
  alias Pleroma.Web.XML
  import Pleroma.Factory

  describe "host meta" do
    test "returns a link to the xml lrdd" do
      host_info = WebFinger.host_meta()

      assert String.contains?(host_info, Pleroma.Web.base_url())
    end
  end

  describe "incoming webfinger request" do
    test "works for fqns no subdomain" do
      user = insert(:user)
      endpoint_env = [{:domain, nil}] ++ Application.get_env(:pleroma, Pleroma.Web.Endpoint)
      Application.put_env(:pleroma, Pleroma.Web.Endpoint, endpoint_env)
      assert endpoint_env[:domain] == nil

      {:ok, result} =
        WebFinger.webfinger("#{user.nickname}@#{Pleroma.Web.Endpoint.host()}", "XML")

      assert is_binary(result)
      {:ok, host_xml} = WebFinger.webfinger_from_xml(XML.parse_document(result))
      assert host_xml["subject"] == "acct:#{user.nickname}@#{Pleroma.Web.Endpoint.host()}"

      {:ok, host_result_json} =
        WebFinger.webfinger("#{user.nickname}@#{Pleroma.Web.Endpoint.host()}", "JSON")

      {:ok, host_json} = WebFinger.webfinger_from_json(host_result_json)
      assert host_json["subject"] == "acct:#{user.nickname}@#{Pleroma.Web.Endpoint.host()}"
    end

    test "works for fqns with subdomain" do
      user = insert(:user)
      domain = "social.localhost"
      endpoint_env = [{:domain, domain}] ++ Application.get_env(:pleroma, Pleroma.Web.Endpoint)
      Application.put_env(:pleroma, Pleroma.Web.Endpoint, endpoint_env)
      assert endpoint_env[:domain] == domain

      {:ok, result} =
        WebFinger.webfinger("#{user.nickname}@#{Pleroma.Web.Endpoint.host()}", "XML")

      {:ok, host_xml} = WebFinger.webfinger_from_xml(XML.parse_document(result))
      assert host_xml["subject"] == "acct:#{user.nickname}@#{domain}"

      {:ok, host_result_json} =
        WebFinger.webfinger("#{user.nickname}@#{Pleroma.Web.Endpoint.host()}", "JSON")

      {:ok, host_json} = WebFinger.webfinger_from_json(host_result_json)
      assert host_json["subject"] == "acct:#{user.nickname}@#{domain}"

      {:ok, domain_result_xml} = WebFinger.webfinger("#{user.nickname}@#{domain}", "XML")
      assert is_binary(domain_result_xml)
      {:ok, domain_xml} = WebFinger.webfinger_from_xml(XML.parse_document(domain_result_xml))
      assert domain_xml["subject"] == "acct:#{user.nickname}@#{domain}"

      {:ok, domain_result_json} = WebFinger.webfinger("#{user.nickname}@#{domain}", "JSON")
      {:ok, domain_json} = WebFinger.webfinger_from_json(domain_result_json)
      assert domain_json["subject"] == "acct:#{user.nickname}@#{domain}"

      assert result == domain_result_xml
      assert host_result_json == domain_result_json
    end

    test "works for ap_ids" do
      user = insert(:user)

      {:ok, result} = WebFinger.webfinger(user.ap_id, "XML")
      assert is_binary(result)
    end
  end

  describe "fingering" do
    test "returns the info for an OStatus user" do
      user = "shp@social.heldscal.la"

      {:ok, data} = WebFinger.finger(user)

      assert data["magic_key"] ==
               "RSA.wQ3i9UA0qmAxZ0WTIp4a-waZn_17Ez1pEEmqmqoooRsG1_BvpmOvLN0G2tEcWWxl2KOtdQMCiPptmQObeZeuj48mdsDZ4ArQinexY2hCCTcbV8Xpswpkb8K05RcKipdg07pnI7tAgQ0VWSZDImncL6YUGlG5YN8b5TjGOwk2VG8=.AQAB"

      assert data["topic"] == "https://social.heldscal.la/api/statuses/user_timeline/29191.atom"
      assert data["subject"] == "acct:shp@social.heldscal.la"
      assert data["salmon"] == "https://social.heldscal.la/main/salmon/user/29191"
    end

    test "returns the ActivityPub actor URI for an ActivityPub user" do
      user = "framasoft@framatube.org"

      {:ok, _data} = WebFinger.finger(user)
    end

    test "returns the ActivityPub actor URI for an ActivityPub user with the ld+json mimetype" do
      user = "kaniini@gerzilla.de"

      {:ok, data} = WebFinger.finger(user)

      assert data["ap_id"] == "https://gerzilla.de/channel/kaniini"
    end

    test "returns the correctly for json ostatus users" do
      user = "winterdienst@gnusocial.de"

      {:ok, data} = WebFinger.finger(user)

      assert data["magic_key"] ==
               "RSA.qfYaxztz7ZELrE4v5WpJrPM99SKI3iv9Y3Tw6nfLGk-4CRljNYqV8IYX2FXjeucC_DKhPNnlF6fXyASpcSmA_qupX9WC66eVhFhZ5OuyBOeLvJ1C4x7Hi7Di8MNBxY3VdQuQR0tTaS_YAZCwASKp7H6XEid3EJpGt0EQZoNzRd8=.AQAB"

      assert data["topic"] == "https://gnusocial.de/api/statuses/user_timeline/249296.atom"
      assert data["subject"] == "acct:winterdienst@gnusocial.de"
      assert data["salmon"] == "https://gnusocial.de/main/salmon/user/249296"
      assert data["subscribe_address"] == "https://gnusocial.de/main/ostatussub?profile={uri}"
    end

    test "it works for friendica" do
      user = "lain@squeet.me"

      {:ok, _data} = WebFinger.finger(user)
    end

    test "it gets the xrd endpoint" do
      {:ok, template} = WebFinger.find_lrdd_template("social.heldscal.la")

      assert template == "https://social.heldscal.la/.well-known/webfinger?resource={uri}"
    end

    test "it gets the xrd endpoint for hubzilla" do
      {:ok, template} = WebFinger.find_lrdd_template("macgirvin.com")

      assert template == "https://macgirvin.com/xrd/?uri={uri}"
    end

    test "it gets the xrd endpoint for statusnet" do
      {:ok, template} = WebFinger.find_lrdd_template("status.alpicola.com")

      assert template == "http://status.alpicola.com/main/xrd?uri={uri}"
    end
  end

  describe "ensure_keys_present" do
    test "it creates keys for a user and stores them in info" do
      user = insert(:user)
      refute is_binary(user.info["keys"])
      {:ok, user} = WebFinger.ensure_keys_present(user)
      assert is_binary(user.info["keys"])
    end

    test "it doesn't create keys if there already are some" do
      user = insert(:user, %{info: %{"keys" => "xxx"}})
      {:ok, user} = WebFinger.ensure_keys_present(user)
      assert user.info["keys"] == "xxx"
    end
  end
end
