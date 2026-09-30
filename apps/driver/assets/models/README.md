# anti_spoof.tflite

MiniFASNet, from
[minivision-ai/Silent-Face-Anti-Spoofing](https://github.com/minivision-ai/Silent-Face-Anti-Spoofing).
Apache 2.0. Converted for LiteRT and mirrored at
[litert-community/Silent-Face-Anti-Spoofing-LiteRT](https://huggingface.co/litert-community/Silent-Face-Anti-Spoofing-LiteRT),
which carries the same Apache 2.0 licence and the model card.

- SHA-256: `4ff758f470b757d9005b418c9978693f09b8f2a5e7b7ee848c160db21208e1b2`
- 1,850,744 bytes
- Input: `[1, 3, 80, 80]` float32, **NCHW**, **BGR**, scaled `x / 255`. The
  channel order is BGR and not RGB; feeding RGB is the single easiest way to
  make this model call a live face a spoof.
- Output: `[1, 2]` softmax. Index 1 is "live", index 0 is "spoof".
- The crop is the face bounding box expanded to about 2.7x its width, squared
  around the box centre and resized to 80x80.

## Why this model and not a hosted API

It is the anti-spoofing half of the face check, it costs nothing per check, it
needs no network, and it is Apache 2.0, which permits commercial use. Every
hosted liveness API charges per verification, and this pilot cannot.

The check is not a claim that photographs cannot get past it. MiniFASNet is a
small model and a printed face held still, at a good angle, in good light is the
hardest case for it. That is exactly why the check is the combination of this
model and the active challenges in `LivenessVerifier`: the challenges prove
something moved in response to an instruction, and this proves the thing moving
in front of the camera is not a flat surface. Neither is strong alone. Together
they are a real check, and both run on the driver's own phone.
