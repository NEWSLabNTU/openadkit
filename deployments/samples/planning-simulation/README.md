# Autoware Open AD Kit Planning Simulation

This sample deployment shows how to run Autoware Open AD Kit **planning simulation**.

## Requirements

In order to run the planning simulation, you need to have the planning simulation **sample map**. You can download it by running the following commands:

### Sample Planning Map

Download and unpack a planning simulation sample map that is used in this sample.

- You can also download [the map](https://drive.google.com/file/d/1499_nsbUbIeturZaDj7jhUownh5fvXHd/view?usp=sharing) manually.

```bash
gdown -O ~/autoware_map/ 'https://docs.google.com/uc?export=download&id=1499_nsbUbIeturZaDj7jhUownh5fvXHd'
unzip -d ~/autoware_map ~/autoware_map/sample-map-planning.zip
```

> **Note**: This sample map(Copyright 2020 TIER IV, Inc.) is only for demonstration purposes. You can use your own map by following the [How-to Guide](https://autowarefoundation.github.io/autoware-documentation/main/how-to-guides/integrating-autoware/creating-maps/).

## Run the Deployment

### x86 (amd64) — using pre-built images from GHCR

1. Start the deployment by running the following command:

    ```bash
    docker compose --env-file planning-simulation.env up -d
    ```

2. Wait for the deployment to start for about 10 seconds and then open a browser to visualize the simulation and navigate to:

    ```bash
    http://localhost:6080/vnc.html
    ```

    Use the default password `openadkit` to access the visualizer. **It can take a few seconds for the visualizer to start.**

    > If your machine is on a remote server, you can access the visualizer by using its accessible IP address:
    >
    > ```bash
    > http://<your-server-ip>:6080/vnc.html
    > ```

3. After you see the visualizer, you can start the autonomous driving simulation by following the [planning simulation instructions](https://autowarefoundation.github.io/autoware-documentation/main/demos/planning-sim/lane-driving/#2-set-an-initial-pose-for-the-ego-vehicle) in the Autoware documentation.

### Jetson (JP62) — using locally-built images

The `docker-compose.jp62.yaml` override replaces all service images with locally-built JP62 images (`openadkit:universe-jp62` for components, `openadkit:visualizer-jp62` for the visualizer). It also adds `runtime: nvidia` for GPU access and sets `ROS_DISTRO=humble` (not baked into JP62 images since they are built from L4T, not the `ros:` Docker base).

> **Prerequisites:** Build the JP62 images first with `./build.sh --platform jp62 --target universe` from the repo root.

1. Start the deployment:

    ```bash
    docker compose -f docker-compose.yaml -f docker-compose.jp62.yaml --env-file planning-simulation.env up -d
    ```

2. Open the visualizer in a browser:

    ```bash
    http://<jetson-ip>:6080/vnc.html
    ```

    Use the default password `openadkit`.

3. Follow the [planning simulation instructions](https://autowarefoundation.github.io/autoware-documentation/main/demos/planning-sim/lane-driving/#2-set-an-initial-pose-for-the-ego-vehicle) to set an initial pose and goal in RViz.

> **Note:** Do not use `docker compose restart` — services share the `map` container's PID namespace (`pid: service:map`), so restarting breaks the namespace reference. Always use `down` followed by `up -d`.

## Stop the Deployment

### x86

```bash
docker compose --env-file planning-simulation.env down
```

### Jetson (JP62)

```bash
docker compose -f docker-compose.yaml -f docker-compose.jp62.yaml --env-file planning-simulation.env down
```
