# Configuring Pleroma

In the `config/` directory, you will find the following relevant files:

* `config.exs`: default base configuration
* `dev.exs`: default additional configuration for `MIX_ENV=dev`
* `prod.exs`: default additional configuration for `MIX_ENV=prod`


Do not modify files in the list above.
Instead, overload the settings by editing the following files:

* `dev.secret.exs`: custom additional configuration for `MIX_ENV=dev`
* `prod.secret.exs`: custom additional configuration for `MIX_ENV=prod`

## Uploads configuration

To configure where to upload files, and wether or not 
you want to remove automatically EXIF data from pictures
being uploaded.

    config :pleroma, Pleroma.Upload,
      uploads: "uploads",
      strip_exif: false

* `uploads`: where to put the uploaded files, relative to pleroma's main directory.
* `strip_exif`: whether or not to remove EXIF data from uploaded pics automatically. 
   This needs Imagemagick installed on the system ( apt install imagemagick ).


## Block functionality

    config :pleroma, :activitypub,
      accept_blocks: true,
      unfollow_blocked: true,
      outgoing_blocks: true

    config :pleroma, :user, deny_follow_blocked: true

* `accept_blocks`: whether to accept incoming block activities from
   other instances
* `unfollow_blocked`: whether blocks result in people getting
   unfollowed
* `outgoing_blocks`: whether to federate blocks to other instances
* `deny_follow_blocked`: whether to disallow following an account that
   has blocked the user in question

## Message Rewrite Filters (MRFs)

Modify incoming and outgoing posts.

    config :pleroma, :instance,
      rewrite_policy: Pleroma.Web.ActivityPub.MRF.NoOpPolicy

`rewrite_policy` specifies which MRF policies to apply.
It can either be a single policy or a list of policies.
Currently, MRFs availible by default are:

* `Pleroma.Web.ActivityPub.MRF.NoOpPolicy`
* `Pleroma.Web.ActivityPub.MRF.DropPolicy`
* `Pleroma.Web.ActivityPub.MRF.SimplePolicy`
* `Pleroma.Web.ActivityPub.MRF.RejectNonPublic`

Some policies, such as SimplePolicy and RejectNonPublic,
can be additionally configured in their respective sections.

### NoOpPolicy

Does not modify posts (this is the default `rewrite_policy`)

### DropPolicy

Drops all posts.
It generally does not make sense to use this in production.

### SimplePolicy

Restricts the visibility of posts from certain instances.

    config :pleroma, :mrf_simple,
      media_removal: [],
      media_nsfw: [],
      federated_timeline_removal: [],
      reject: [],
      accept: []

* `media_removal`: posts from these instances will have attachments 
   removed
* `media_nsfw`: posts from these instances will have attachments marked
   as nsfw
* `federated_timeline_removal`: posts from these instances will be 
   marked as unlisted
* `reject`: posts from these instances will be dropped
* `accept`: if not empty, only posts from these instances will be accepted

### RejectNonPublic

Drops posts with non-public visibility settings.

    config :pleroma :mrf_rejectnonpublic
      allow_followersonly: false,
      allow_direct: false,

* `allow_followersonly`: whether to allow follower-only posts through
   the filter
* `allow_direct`: whether to allow direct messages through the filter

## Serving Pleroma from a subdomain

Users are primarily identified by user@example.com. If you are already
serving content at example.com and want to host Pleroma on
social.example.com but you want to make this identifier the same as, say,
your email or your XMPP handle, then you should follow these steps:

1. When running generate_config, enter the subdomain from which you are
   serving Pleroma (e.g. social.example.com).
2. Uncomment out the domain key in the generated config. It should be
   populated by default with the subdomain. Change it to the domain you
   want to use for your handles (e.g. example.com). Leave the host value
   in the uri key untouched.
3. Forward requests for example.com/.well-known/webfinger to
   social.example.com/.well-known/webfinger
   This will need to be done in the configuration for whatever web server
   is hosting content on example.com.

If you are not hosting a web server on example.com, or you cannot
configure either proxying or a redirect for step 3 from that server to
Pleroma, then you will not be able to configure Pleroma this way.
