({ ... }:
{
  config = {
    fileSystems = {
      "/userdata" = {
        device = "UUID=${builtins.readFile ./uuid.json}";
        options = [ "bind" "X-mount.mkdir" ];
      };
    };
  };
})
