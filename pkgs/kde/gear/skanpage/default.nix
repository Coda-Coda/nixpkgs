{
  mkKdeDerivation,
  qtwebengine,
  tesseractLanguages ? [ ],
  tesseract5,
  leptonica,
}:
mkKdeDerivation {
  pname = "skanpage";

  extraNativeBuildInputs = [
    qtwebengine
  ];

  extraBuildInputs = [
    qtwebengine
    (tesseract5.override { enableLanguages = tesseractLanguages; })
    leptonica
  ];

  meta.mainProgram = "skanpage";
}
