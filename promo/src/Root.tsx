import { Composition } from "remotion";
import { Promo, FPS, TOTAL } from "./Promo";

export const Root = () => (
  <Composition id="Promo" component={Promo} durationInFrames={TOTAL * FPS} fps={FPS} width={1440} height={1080} />
);
