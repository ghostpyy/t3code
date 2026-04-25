{
  "targets": [
    {
      "target_name": "simview",
      "sources": [
        "src/addon.mm",
        "src/simview.mm"
      ],
      "include_dirs": [
        "<!(node -p \"require('node-addon-api').include_dir\")"
      ],
      "defines": ["NAPI_DISABLE_CPP_EXCEPTIONS"],
      "cflags_cc": ["-fexceptions"],
      "conditions": [
        ["OS=='mac'", {
          "xcode_settings": {
            "MACOSX_DEPLOYMENT_TARGET": "13.0",
            "OTHER_CFLAGS": ["-fobjc-arc"],
            "OTHER_CPLUSPLUSFLAGS": ["-std=gnu++17", "-stdlib=libc++", "-fobjc-arc"],
            "OTHER_LDFLAGS": [
              "-framework", "AppKit",
              "-framework", "QuartzCore"
            ]
          }
        }]
      ]
    }
  ]
}
