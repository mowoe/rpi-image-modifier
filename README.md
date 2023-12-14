# Raspberry Pi OS Image Modifier GitHub Action

GitHub Action to modify a base Docker image

## Action Inputs

|  Input name        |  Description                                                                          |  Default                |
|-------------------:|---------------------------------------------------------------------------------------|-------------------------|
| `base-image-url`   | Base Raspberry Pi OS image URL (required)                                             | -                       |
| `script-path`      | Path of script to run to modify image (one of script-path or run is required)         | -                       |
| `run`              | Bash script containers to run to modify image (one of script-path or run is required) | -                       |
| `image-path`       | What to name the modified image                                                       | `'rpi-os-modified.img'` |
| `mount-repository` | Temporary mount repository at /mounted-github-repo/ for copying files                 | `'true'`                |
| `compress-with-xz` | Compress final image with xz (image-path will have an .xz extension added)            | `'false'`               |
| `shell`            | Shell in container to execute script                                                  | `'/bin/bash'`           |
| `image-maxsize`    | That maximum size of the modified image (needs to fit on disk)                        | `'12G'`                 |


## Action Outputs

| Output name  | Description                                                                                                             |
|------------- |-------------------------------------------------------------------------------------------------------------------------|
| `image-path` | Filename of image, will be same as image-path unless compress-with-xz is set in which case it will have a .xz extension |


## Example

```
name: ci

on:
  push:

jobs:
  modify-rpi-image:
    runs-on: ubuntu-latest
    steps:
      -
        name: Add pygame to Raspberry Pi OS Bookworm
        uses: dtcooper/rpi-image-modifier@main
        id: modify-image
        with:
          base-image-url: https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2023-12-06/2023-12-05-raspios-bookworm-arm64-lite.img.xz
          run: |
            apt-get update
            apt-get install -y python3-pygame
          image-path: 2023-12-05-raspios-bookworm-arm64-lite-with-pygame.img
          compress-with-xz: true
      -
        name: Update build artifact
        uses: actions/upload-artifact@v3
        with:
          name: modified-image
          path: ${{ steps.modify-image.outputs.image-path }}
          retention-days: 1
```
