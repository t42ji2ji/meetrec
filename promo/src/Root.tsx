import { Composition } from "remotion";
import { Promo, FPS, TOTAL } from "./Promo";
import { CLIP, FeatureDual, FeatureImport, FeatureSpeakers } from "./Features";

export const Root = () => (
  <>
    <Composition id="Promo" component={Promo} durationInFrames={TOTAL * FPS} fps={FPS} width={1440} height={1080} />
    <Composition id="FeatureImport" component={FeatureImport} durationInFrames={CLIP * FPS} fps={FPS} width={1440} height={1080} />
    <Composition id="FeatureSpeakers" component={FeatureSpeakers} durationInFrames={CLIP * FPS} fps={FPS} width={1440} height={1080} />
    <Composition id="FeatureDual" component={FeatureDual} durationInFrames={CLIP * FPS} fps={FPS} width={1440} height={1080} />
  </>
);
