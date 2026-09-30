# anti_spoof.tflite

MiniFASNet, from
[minivision-ai/Silent-Face-Anti-Spoofing](https://github.com/minivision-ai/Silent-Face-Anti-Spoofing).
Apache 2.0. Converted for LiteRT and mirrored at
[litert-community/Silent-Face-Anti-Spoofing-LiteRT](https://huggingface.co/litert-community/Silent-Face-Anti-Spoofing-LiteRT),
which carries the same Apache 2.0 licence and the model card.

- SHA-256: `4ff758f470b757d9005b418c9978693f09b8f2a5e7b7ee848c160db21208e1b2`
- 1,850,744 bytes
- Input: `[1, 3, 80, 80]` float32, **NCHW**, **BGR**, scaled `x / 255`. The
  channel order is BGR and not RGB.
- Output: `[1, 3]`, **already softmaxed** -- the values sum to 1.0 as they come
  out, so no second normalisation is applied. The classes are:

  | index | meaning |
  | --- | --- |
  | 0 | 2D presentation attack: a printed photograph or a screen |
  | 1 | 3D presentation attack: a mask or another 3D replica |
  | 2 | **a real, live face** |

  Index 2 is the score this app uses. MiniFASNetV2 is a three-class network and
  the reference implementation reads `pred[2]`, padding a two-class model up to
  three so both variants share one line.

  **The model card on the HuggingFace mirror describes a two-class output. It
  is wrong.** Found by running the real weights: `anti_spoof_model_test.dart`
  fails against a `[1, 2]` buffer with `Output object shape mismatch`. The
  symptom in the app is a face check that reports nothing at all, silently,
  because the anti-spoof pass throws and the verifier counts the frame as
  unmeasured.

- The crop is the face bounding box expanded to about 2.7x its width, squared
  around the box centre and resized to 80x80.

## What has and has not been measured

Measured, and asserted in `anti_spoof_model_test.dart`: the file is present and
the right size; the tensor the crop builder produces is exactly what the model
accepts; the output is a three-class softmax summing to 1; class 2 dominates;
different images score differently; the same image always scores the same; and
a black, white or mid-grey frame produces an all-zero, all-one or mid-grey
tensor, which is what proves the normalisation and the channel planes are
right.

**Not measured:** whether this model rejects a photograph. It needs a live face
and a printed photograph of that same face, and there is no such pair in a unit
test. Given a black frame, a white frame and random noise it answers about
0.99 "live" in all three, which is what a model does with input outside its
training distribution. So the threshold in `SpoofDetector.liveThreshold` has no
measured false-accept rate, which is why `livenessFrame.isRequired` is still
false.

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
