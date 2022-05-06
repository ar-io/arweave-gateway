import pkg from "aws-sdk";
const { S3 } = pkg;

export const s3 = new S3({
  httpOptions: { timeout: 60000, connectTimeout: 5000 },
});

export const put = async (key, body, contentType) => {
  await s3
    .upload({
      Key: key,
      Bucket: process.env.ARWEAVE_S3_TX_DATA_BUCKET,
      Body: body,
      ContentType: contentType,
    })
    .promise();
};
