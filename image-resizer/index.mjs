import * as Sentry from "@sentry/aws-serverless";
import {
  S3Client,
  GetObjectCommand,
  PutObjectCommand,
  DeleteObjectCommand,
} from "@aws-sdk/client-s3";
import sharp from "sharp";

// Sentry must be initialized before any other code runs.
// If SENTRY_DSN is not set the SDK is a no-op, so local/dev invocations
// work without any configuration change.
Sentry.init({
  dsn: process.env.SENTRY_DSN,
  tracesSampleRate: 0.1,
  environment: process.env.SENTRY_ENVIRONMENT ?? "production",
  // Tag every event so it is easy to filter in the Sentry dashboard
  initialScope: {
    tags: { lambda: "image-resizer", service: "special-tech" },
  },
});

const s3 = new S3Client({});

const MAX_WIDTH = 1920;
const JPEG_QUALITY = 82;

/**
 * Converts a readable stream into a Buffer.
 * @param {import('stream').Readable} stream
 * @returns {Promise<Buffer>}
 */
async function streamToBuffer(stream) {
  const chunks = [];
  for await (const chunk of stream) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks);
}

/**
 * Derives the final (compressed) S3 key from the original key by removing
 * the "/originals/" path segment that the mobile app uploads to.
 *
 * Example:
 *   work-orders/abc/originals/front.jpg  →  work-orders/abc/front.jpg
 *
 * @param {string} rawKey
 * @returns {string}
 */
function toFinalKey(rawKey) {
  return rawKey.replace("/originals/", "/");
}

/**
 * Processes a single S3 record: downloads, compresses and re-uploads the image.
 *
 * @param {string} bucket
 * @param {string} rawKey
 */
async function processRecord(bucket, rawKey) {
  const finalKey = toFinalKey(rawKey);

  // Attach context so every Sentry event for this record carries the S3 details
  Sentry.setContext("s3_record", { bucket, rawKey, finalKey });

  console.log(`Processing: s3://${bucket}/${rawKey} → ${finalKey}`);

  // Download original
  let getResponse;
  try {
    getResponse = await s3.send(
      new GetObjectCommand({ Bucket: bucket, Key: rawKey }),
    );
  } catch (err) {
    Sentry.captureException(err, {
      extra: { step: "GetObject", bucket, rawKey },
    });
    throw err;
  }

  const originalBuffer = await streamToBuffer(getResponse.Body);

  // Resize and compress with Sharp
  let compressedBuffer;
  try {
    compressedBuffer = await sharp(originalBuffer)
      .rotate() // auto-rotate based on EXIF orientation
      .resize({ width: MAX_WIDTH, withoutEnlargement: true })
      .jpeg({ quality: JPEG_QUALITY, progressive: true })
      .toBuffer();
  } catch (err) {
    Sentry.captureException(err, {
      extra: {
        step: "sharp_resize",
        bucket,
        rawKey,
        originalSizeBytes: originalBuffer.length,
      },
    });
    throw err;
  }

  const originalKB = Math.round(originalBuffer.length / 1024);
  const compressedKB = Math.round(compressedBuffer.length / 1024);
  console.log(`Size: ${originalKB} KB → ${compressedKB} KB`);

  // Upload compressed image to final key
  try {
    await s3.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: finalKey,
        Body: compressedBuffer,
        ContentType: "image/jpeg",
      }),
    );
  } catch (err) {
    Sentry.captureException(err, {
      extra: { step: "PutObject", bucket, finalKey },
    });
    throw err;
  }

  // Delete original to avoid paying for duplicate storage
  try {
    await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: rawKey }));
  } catch (err) {
    // Deletion failure is non-critical: the compressed file is already saved.
    // Log to Sentry as warning so it shows up without alerting as an error.
    console.warn(`Failed to delete original: ${rawKey}`, err);
    Sentry.captureException(err, {
      level: "warning",
      extra: { step: "DeleteObject", bucket, rawKey },
    });
  }

  console.log(`Done: ${finalKey}`);
}

/**
 * Lambda handler triggered by S3 PutObject events on the "originals/" prefix.
 *
 * Wrapped with Sentry.wrapHandler so that:
 *  - Unhandled errors are automatically captured and reported.
 *  - Each invocation is tracked as a Sentry transaction/trace.
 *  - Sentry flushes its queue before the Lambda container freezes.
 *
 * @param {import('aws-lambda').S3Event} event
 */
export const handler = Sentry.wrapHandler(async (event) => {
  for (const record of event.Records) {
    const bucket = record.s3.bucket.name;
    // Keys from S3 events are URL-encoded
    const rawKey = decodeURIComponent(record.s3.object.key.replace(/\+/g, " "));

    if (!rawKey.includes("/originals/")) {
      // Safety guard: ignore objects that are not in the originals folder
      // to prevent processing already-compressed images.
      console.log(`Skipping non-original key: ${rawKey}`);
      continue;
    }

    await processRecord(bucket, rawKey);
  }
});
