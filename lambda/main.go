// Package main
package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/s3"
	"github.com/aws/aws-sdk-go/service/s3/s3manager"
)

func storeLocally(sess *session.Session, s3Event events.S3Event) ([]string, error) {
	// loop over all the records in the received event
	// for the purposes of this example we're expecting one or many
	// records per event
	filenames := []string{}
	log.Print("About to loop over records")
	for _, record := range s3Event.Records {
		// create a file with the same name as the file that will be retrieved
		log.Printf("Creating file locally %s", record.S3.Object.Key)
		file, err := os.Create("/tmp/" + record.S3.Object.Key)
		if err != nil {
			log.Printf("Error creating file %v", err)
			return []string{}, err
		}

		defer file.Close()

		log.Printf("Downloading from %s", record.S3.Bucket.Name)
		downloader := s3manager.NewDownloader(sess)
		// download the object, and store it in the local file
		_, err = downloader.Download(file,
			&s3.GetObjectInput{
				Bucket: &record.S3.Bucket.Name,
				Key:    &record.S3.Object.Key,
			})
		if err != nil {
			log.Printf("Error downloading file %v", err)
			return []string{}, err
		}
		filenames = append(filenames, "/tmp/"+record.S3.Object.Key)
	}
	log.Printf("have %d filenames %s", len(filenames), filenames[0])
	return filenames, nil
}

func upload(sess *session.Session, filenames []string, bucket string) error {
	uploader := s3manager.NewUploader(sess)

	log.Print("Uploads")
	for _, filename := range filenames {
		file, err := os.Open(filename)
		if err != nil {
			log.Printf("Open File error %v", err)
			return fmt.Errorf("uploadFile::: Unable to open file %s, %v", filename, err)
		}

		defer file.Close()

		_, err = uploader.Upload(&s3manager.UploadInput{
			Bucket: &bucket,
			Key:    &filename,
			Body:   file,
		})

		if err != nil {
			// Print the error and exit.
			log.Printf("Upload error %v", err)
			return fmt.Errorf("Unable to upload %q to %q, %v", filename, bucket, err)
		}
	}
	log.Print("Uploads complete")
	return nil
}

// s3 event handler
func handler(ctx context.Context, s3Event events.S3Event) {
	sess := session.Must(session.NewSessionWithOptions(session.Options{
		SharedConfigState: session.SharedConfigEnable,
	}))
	filenames, err := storeLocally(sess, s3Event)
	if err != nil {
		log.Printf("ERROR unable to store files locally with error %v", err)
		return
	}
	// I have chosen to download from one s3, then upload the data to another s3
	// in two steps, instead of using the CopyObject API
	// https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html
	// because this intermediate step is where processing would occur, for
	// example, if the upstream object was YAML, and the downstream object
	// needed to be JSON, the transformation would occur here.
	targetBucket := os.Getenv("DST_BUCKET")

	err = upload(sess, filenames, targetBucket)
	if err != nil {
		log.Printf("ERROR unable to upload files with error %v", err)
	}
}

func main() {
	// Make the handler available for Remote Procedure Call by AWS Lambda
	lambda.Start(handler)
}
