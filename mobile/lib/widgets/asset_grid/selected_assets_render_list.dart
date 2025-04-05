import 'package:immich_mobile/entities/asset.entity.dart';
import 'package:immich_mobile/widgets/asset_grid/asset_grid_data_structure.dart';

/// A simple implementation of RenderList that just holds a fixed list of assets.
/// Used for viewing a specific selection of assets (e.g., search results, shared links, selection).
class SelectedAssetsRenderList extends RenderList {
  SelectedAssetsRenderList(List<Asset> selectedAssets)
      : super(
          // Create a single element representing all assets
          selectedAssets.isEmpty
              ? [] // Handle empty case explicitly
              : [
                  RenderAssetGridElement(
                    RenderAssetGridElementType
                        .assetRow, // Positional 'type' argument
                    date: DateTime.now(), // Named 'date' argument (dummy value)
                    offset: 0, // Named 'offset'
                    count: selectedAssets.length, // Named 'count'
                    totalCount: selectedAssets.length, // Named 'totalCount'
                    // title: "Locked Assets", // Optional named 'title'
                  ),
                ],
          null, // No query needed
          selectedAssets, // Pass the full list
        );

  // The base RenderList class handles totalAssets getter and loadAsset method
  // correctly when the 'allAssets' parameter is provided in the constructor.
  // No further overrides are needed for basic GalleryViewerPage usage.
}
